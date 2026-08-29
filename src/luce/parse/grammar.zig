//! The Luce parser: declarations and statements.
//!
//! Handwritten recursive descent over the declaration and statement
//! grammar; the Pratt expression parser it calls into lives in
//! expressions.zig.
//!
//! Three properties this file is responsible for, beyond the grammar:
//!
//! **Recovery.**  A broken construct reports once and then resumes at
//! the next line of the same block — and, when the broken line was a
//! header, the orphaned indented body is swallowed rather than read as
//! if it stood at the outer level.  Without that second half, one
//! missing `:` turns every statement of the body into a lie.
//!
//! **Reading on where the intent is unmistakable.**  A header missing
//! its `:` is reported and then read anyway whenever the layout says a
//! block was meant; `if x = 1:` is reported at the `=` and then read as
//! the comparison.  Bailing out is the safe move only when the guess
//! would be one — when it would not be, bailing out costs the reader
//! every diagnostic in the body below, which is the same cascade the
//! paragraph above exists to prevent, arriving from the other side.
//!
//! **Bounded recursion.**  Every recursive entry — a statement, a
//! conditional, an expression, a type argument — passes through
//! `Parser.enter`, so hostile or generated input reports
//! `luce.parse.nesting` instead of walking off the native stack.

const std = @import("std");
const source_mod = @import("../source.zig");
const lex_mod = @import("../lex.zig");
const ast = @import("ast.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");
const expr = @import("expressions.zig");

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const Token = lex_mod.Token;
const Kind = lex_mod.Kind;
const Diagnostics = diagnostics_mod.Diagnostics;

pub const Error = error{OutOfMemory};

/// How many parse diagnostics one `parse()` call reports before it
/// falls silent with a single `luce.parse.limit`.  Matches stage 2's
/// cap for the same reason: a file of noise is a hundred messages,
/// not a hundred thousand.
const max_diagnostics = 100;

/// Parse a whole program.  The AST is allocated from `arena` and lives
/// exactly as long as it; token storage is temporary.  Parse problems
/// land in `diagnostics` — a program with errors may still return a
/// partial tree for further reporting.
///
/// **Precondition:** `source` is stage 1's prepared text, inherited
/// whole from `lex()` — valid UTF-8, LF endings, no NUL, no leading
/// byte-order mark (`source.prepare`).  Every span this stage
/// produces indexes it.
// ---------------------------------------------------------------------------
// Parsing a file
// ---------------------------------------------------------------------------

pub fn parse(
    arena: Allocator,
    temporary: Allocator,
    source: []const u8,
    diagnostics: *Diagnostics,
) Error!ast.Program {
    // Which diagnostics are stage 2's, for this file: everything it
    // adds between here and the line below.  Read out of the shared
    // list rather than carried on `Lexed`, because the list is where
    // they already are and a second copy is a second thing to keep
    // true.
    const before_lex = diagnostics.count();
    const lexed = try lex_mod.lex(temporary, source, diagnostics);
    defer temporary.free(lexed.tokens);

    var parser: Parser = .{
        .arena = arena,
        .source = source,
        .tokens = lexed.tokens,
        .diagnostics = diagnostics,
        .silenced = lexed.truncated,
        .lexed_first = before_lex,
        .lexed_last = diagnostics.count(),
    };
    return parser.program();
}

// ---------------------------------------------------------------------------
// The parser
// ---------------------------------------------------------------------------

pub const Parser = struct {
    arena: Allocator,
    source: []const u8,
    /// Always ends with an `end_of_file` token — stage 2 guarantees
    /// it, and every lookahead here relies on it.
    tokens: []const Token,
    diagnostics: *Diagnostics,
    index: usize = 0,
    /// Recursive-descent depth, so a pathological `((((…))))`, a long
    /// prefix-operator chain, a tower of nested blocks, or a nest of
    /// type arguments reports an error instead of overflowing the
    /// native stack.  Generous: real code never approaches it; only
    /// hostile or generated input does.
    depth: u32 = 0,
    /// The nesting bound is one condition, not one per unwinding
    /// frame: report it once and stay quiet while the stack unwinds.
    nesting_reported: bool = false,
    /// How many diagnostics this parse has added, for the report cap.
    /// Counted here rather than read from `diagnostics`, which the
    /// lexer has already written into.
    reported: usize = 0,
    /// Set when stage 2 stopped early on a structural bound
    /// (`lex_mod.Lexed.truncated`).  The file has been refused by
    /// name; the tail of the token stream is the lexer closing its own
    /// open blocks, and every complaint this stage could make about it
    /// — starting with the innermost block looking empty — would be
    /// the compiler talking to itself.  So it says nothing.
    silenced: bool = false,
    /// The half-open range of `diagnostics` that stage 2 wrote for
    /// this file.  `statementIsLexerDamage` reads their spans.
    lexed_first: usize = 0,
    lexed_last: usize = 0,
    /// Where the statement being parsed started, in bytes.  A stray
    /// character is dropped by stage 2, so what reaches this stage is
    /// a statement with a hole in it, and the complaint about the hole
    /// is the *same mistake* reported twice (`if a && a:` was "there
    /// is no '&&' operator" and then "expected ':', found 'a'").  The
    /// rule is the one `silenced` already applies to a truncated file,
    /// narrowed to one construct: if stage 2 spoke inside the source
    /// this statement has consumed, this stage has nothing to add.
    statement_start: usize = 0,

    pub const max_depth: u32 = 512;

    // -- the token cursor -------------------------------------------------
    //
    // Every `pub` method on `Parser` is `expressions.zig`'s
    // contract and nothing else: the sibling drives this cursor,
    // spends this file's recursion budget, reports through this
    // file's diagnostics, and asks it for a written type.  What
    // is not marked is private to this file, which is every
    // production the grammar has — the sibling parses
    // expressions, never a declaration and never a statement.

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

    /// The whole token `ahead` of the cursor, for the checks that need
    /// its span — whether two operator characters touch, and so were
    /// one operator the reader meant, decides how they are read back.
    pub fn tokenAhead(self: *const Parser, ahead: usize) Token {
        const at = @min(self.index + ahead, self.tokens.len - 1);
        return self.tokens[at];
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

    pub fn text(self: *const Parser, item: Token) []const u8 {
        return item.span.slice(self.source);
    }

    // -- bounded recursion ------------------------------------------------

    /// Take one level of recursive descent, reporting once when the
    /// bound is reached.  Returns false to mean "unwind"; callers
    /// pair a true result with `defer self.leave()`.
    pub fn enter(self: *Parser, what: []const u8) Error!bool {
        if (self.depth >= max_depth) {
            if (!self.nesting_reported) {
                self.nesting_reported = true;
                try self.report(
                    "luce.parse.nesting",
                    self.peek().span,
                    "{s} nested too deeply (limit {d})",
                    .{ what, max_depth },
                );
            }
            return false;
        }
        self.depth += 1;
        return true;
    }

    pub fn leave(self: *Parser) void {
        self.depth -= 1;
    }

    // -- reporting and recovery -------------------------------------------

    /// Add one parse diagnostic, honoring the report cap.  Every
    /// diagnostic in this stage goes through here; recovery keeps
    /// running either way, so the tree never depends on how many
    /// errors came before.
    pub fn report(
        self: *Parser,
        code: []const u8,
        span: Span,
        comptime format: []const u8,
        arguments: anytype,
    ) Error!void {
        if (self.silenced) return;
        if (self.statementIsLexerDamage(span)) return;
        if (self.reported > max_diagnostics) return;
        if (self.reported == max_diagnostics) {
            self.reported += 1;
            try self.diagnostics.add(
                "luce.parse.limit",
                span,
                "too many parse errors; only the first {d} are reported",
                .{max_diagnostics},
            );
            return;
        }
        self.reported += 1;
        try self.diagnostics.add(code, span, format, arguments);
    }

    /// True when stage 2 already reported inside the statement being
    /// parsed, up to and including what this report is about.
    ///
    /// Stage 2 drops the character it complains about, so the token
    /// stream reaching this stage has a hole where it was, and every
    /// complaint about the hole is the first mistake said again in
    /// worse words.  A lexical report *before* this statement began is
    /// a different mistake and does not silence anything, so a file
    /// with one bad line still reports the next one.
    ///
    /// Linear in stage 2's diagnostics, which is a handful in any file
    /// that gets this far and capped at a hundred in one that does not.
    fn statementIsLexerDamage(self: *const Parser, span: Span) bool {
        for (self.lexed_first..self.lexed_last) |index| {
            const lexical = self.diagnostics.at(index) orelse continue;
            if (lexical.span.start < self.statement_start) continue;
            if (lexical.span.start <= span.end) return true;
        }
        return false;
    }

    /// Report "expected `what`, found X" at the offending token — the
    /// token the parser is looking at, never the one after it.
    fn expected(self: *Parser, what: []const u8) Error!void {
        try self.report(
            "luce.parse.expected",
            self.peek().span,
            "expected {s}, found {s}",
            .{ what, try self.found() },
        );
    }

    pub fn expect(self: *Parser, kind: Kind, what: []const u8) Error!?Token {
        if (self.accept(kind)) |item| return item;
        // A keyword where a name belongs is its own mistake, and
        // "expected a binding name, found the keyword 'for'" reads as
        // a puzzle; say what the fix is.
        if (kind == .identifier) {
            if (keywordWord(self.peekKind())) |word| {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "expected {s}, but '{s}' is a keyword and cannot be used as a name",
                    .{ what, word },
                );
                return null;
            }
        }
        try self.expected(what);
        return null;
    }

    /// True when no line break separates the two offsets — the test
    /// behind every diagnostic that has to choose between blaming the
    /// token in front of it and blaming an opener further back.
    /// Brackets suspend newlines, so this reads the source text, not
    /// the token stream.
    fn sameLine(self: *const Parser, from: usize, to: usize) bool {
        const start = @min(from, self.source.len);
        const end = @min(@max(to, start), self.source.len);
        return std.mem.indexOfScalar(u8, self.source[start..end], '\n') == null;
    }

    /// The source behind `span`, when it is short enough and plain
    /// enough to quote back inside a message.  Diagnostics that
    /// suggest a rewrite use the reader's own words when they can and
    /// fall back to placeholders when they cannot, rather than pasting
    /// half a screen into one line.
    pub fn quotable(self: *const Parser, span: Span) ?[]const u8 {
        if (span.end <= span.start or span.end > self.source.len) return null;
        const text_slice = self.source[span.start..span.end];
        if (text_slice.len > 32) return null;
        if (std.mem.indexOfScalar(u8, text_slice, '\n') != null) return null;
        return text_slice;
    }

    /// Expect the token closing `opener`.  Inside brackets the lexer
    /// suspends newlines, so an unclosed one silently swallows the
    /// lines that follow: point at the offending token while the group
    /// is still on its opening line, and at the opener itself once it
    /// has run past it, which is the only place the fix belongs.
    pub fn expectClose(self: *Parser, kind: Kind, opener: Token) Error!?Token {
        if (self.accept(kind)) |item| return item;
        const found_token = self.peek();
        if (self.sameLine(opener.span.end, found_token.span.start)) {
            try self.report(
                "luce.parse.expected",
                found_token.span,
                "expected {s} to close {s}, found {s}",
                .{ describe(kind), describe(opener.kind), try self.found() },
            );
        } else {
            try self.report(
                "luce.parse.expected",
                opener.span,
                "unclosed {s} — no matching {s}",
                .{ describe(opener.kind), describe(kind) },
            );
        }
        return null;
    }

    /// A comma-separated list stopped, and what it stopped in front of
    /// plainly starts another element on the same line: the mistake is
    /// the separator, not the closer.  "missing ',' before 'y'" is the
    /// fix; "expected ')' to close '(', found 'y'" is a description of
    /// the parser's predicament.  Same-line only — across a line break
    /// the honest answer is the unclosed bracket, which `expectClose`
    /// then gives.  Returns true when it reported.
    pub fn missingSeparator(self: *Parser, previous_end: usize) Error!bool {
        const item = self.peek();
        if (!expr.startsExpression(item.kind)) return false;
        if (!self.sameLine(previous_end, item.span.start)) return false;
        try self.report(
            "luce.parse.expected",
            item.span,
            "missing ',' before {s}",
            .{try self.found()},
        );
        return true;
    }

    /// A human phrase for the token the parser is looking at, for
    /// "…, found X" messages.  Names come through quoted, because the
    /// exact word is the clue; every other kind has a fixed English
    /// name.  Arena-allocated when it quotes, so it lives as long as
    /// the message is being formatted.
    pub fn found(self: *Parser) Error![]const u8 {
        return switch (self.peekKind()) {
            .identifier => try std.fmt.allocPrint(self.arena, "'{s}'", .{self.text(self.peek())}),
            else => describe(self.peekKind()),
        };
    }

    /// Resume after a broken construct: drop the rest of the current
    /// line, then drop the indented block that followed it, if any.
    /// The second half is what keeps one missing `:` from turning a
    /// whole function body into nonsense at the outer level.
    fn recover(self: *Parser) void {
        self.syncToLine();
        self.skipIndentedBlock();
    }

    /// Skip to the start of the next line at the current block level.
    /// A nested block encountered on the way is consumed whole.
    fn syncToLine(self: *Parser) void {
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
                    // Back at the level we started from, at the head of
                    // a line: stop before eating the next declaration.
                    if (depth == 0) return;
                },
                else => _ = self.advance(),
            }
        }
    }

    // -- blocks, and what a header owes -----------------------------------

    /// The `:` that opens a block body.  A missing one is the commonest
    /// mistake there is in an indentation language, and bailing out
    /// here costs the reader every diagnostic in the body below — the
    /// very cascade the recovery exists to prevent.  So: report it, and
    /// then keep going whenever the *layout* says a block was plainly
    /// meant anyway (a line end followed by an indent).  Returns false
    /// only when there is no body to read on into.
    fn colonOrLayout(self: *Parser, what: []const u8) Error!bool {
        if (self.accept(.colon) != null) return true;
        if (self.peekKind() == .left_brace) {
            try self.report(
                "luce.parse.expected",
                self.peek().span,
                "blocks open with ':' and an indented body; '{{' starts a map literal",
                .{},
            );
            return false;
        }
        try self.expected(what);
        return self.peekKind() == .newline and self.peekAhead(1) == .indent;
    }

    /// The `indent` that opens a block body, or the diagnostic for the
    /// two ways it can be missing.  A block that runs straight into a
    /// dedent or end of file is *empty*, and saying so is the whole
    /// message; "expected an indented block, found the end of a block"
    /// is the parser talking to itself.
    fn blockBody(self: *Parser, opener: []const u8) Error!?Token {
        if (self.accept(.indent)) |opened| return opened;
        if (self.peekKind() == .dedent or self.peekKind() == .end_of_file) {
            try self.report(
                "luce.parse.expected",
                self.peek().span,
                "this '{s}' block is empty: indent at least one statement under it",
                .{opener},
            );
            return null;
        }
        try self.report(
            "luce.parse.expected",
            self.peek().span,
            "expected an indented block under '{s}', found {s}",
            .{ opener, try self.found() },
        );
        return null;
    }

    /// A line indented further than the block it sits in, with no
    /// header above it to justify the step.  Report the step and
    /// swallow the whole over-indented run, so its statements are
    /// neither read at the wrong level nor reported one by one.
    fn unexpectedIndent(self: *Parser) Error!void {
        try self.report(
            "luce.parse.indent",
            self.peek().span,
            "unexpected indentation: nothing above this line opens a block",
            .{},
        );
        self.skipIndentedBlock();
    }

    /// Swallow an indented block whose header did not parse, so its
    /// statements are never read as if they stood one level out.
    fn skipIndentedBlock(self: *Parser) void {
        if (self.peekKind() != .indent) return;
        var depth: usize = 0;
        while (true) {
            switch (self.peekKind()) {
                .end_of_file => return,
                .indent => {
                    depth += 1;
                    _ = self.advance();
                },
                .dedent => {
                    if (depth == 0) return;
                    depth -= 1;
                    _ = self.advance();
                    if (depth == 0) return;
                },
                else => _ = self.advance(),
            }
        }
    }

    /// True for the block-structured expressions — a block closure and
    /// an expression-valued match — which consume their own trailing
    /// newline, indentation, and dedent.  A statement whose value is
    /// one of these has already reached the end of its line, so the
    /// caller must not also demand a newline.
    fn endsWithBlock(value: *const ast.Expression) bool {
        return switch (value.*) {
            .closure, .match_value => true,
            else => false,
        };
    }

    /// Every statement ends at a newline.  When one does not, report
    /// once and drop the rest of the line: parsing the leftovers as a
    /// fresh statement is how a single mistake becomes four.
    fn endOfStatement(self: *Parser, what: []const u8) Error!void {
        if (self.accept(.newline) != null) return;
        if (self.peekKind() == .end_of_file) return;
        try self.expected(what);
        self.recover();
    }

    // -- the file: imports and private markers ----------------------------

    fn program(self: *Parser) Error!ast.Program {
        var imports: std.ArrayList(ast.Import) = .empty;
        defer imports.deinit(self.arena);
        var constants: std.ArrayList(ast.ConstDecl) = .empty;
        defer constants.deinit(self.arena);
        var aliases: std.ArrayList(ast.AliasDecl) = .empty;
        defer aliases.deinit(self.arena);
        var structs: std.ArrayList(ast.StructDecl) = .empty;
        defer structs.deinit(self.arena);
        var interfaces: std.ArrayList(ast.InterfaceDecl) = .empty;
        defer interfaces.deinit(self.arena);
        var enums: std.ArrayList(ast.EnumDecl) = .empty;
        defer enums.deinit(self.arena);
        var unions: std.ArrayList(ast.UnionDecl) = .empty;
        defer unions.deinit(self.arena);
        var functions: std.ArrayList(ast.FuncDecl) = .empty;
        defer functions.deinit(self.arena);
        var externs: std.ArrayList(ast.ExternDecl) = .empty;
        defer externs.deinit(self.arena);
        var extern_types: std.ArrayList(ast.ExternTypeDecl) = .empty;
        defer extern_types.deinit(self.arena);
        var extern_vars: std.ArrayList(ast.ExternVarDecl) = .empty;
        defer extern_vars.deinit(self.arena);

        while (self.peekKind() != .end_of_file) {
            if (self.atIndirectUnion()) {
                if (try self.indirectUnion()) |declaration| {
                    try unions.append(self.arena, declaration);
                } else {
                    self.recover();
                }
                continue;
            }
            switch (self.peekKind()) {
                .newline => _ = self.advance(),
                // Layout tokens at file scope mean the file itself
                // starts indented, or a header above already failed.
                // Say so, and consume them, so the loop always moves.
                .indent => {
                    try self.report(
                        "luce.parse.top",
                        self.peek().span,
                        "unexpected indentation: declarations start at the left margin",
                        .{},
                    );
                    self.skipIndentedBlock();
                },
                .dedent => _ = self.advance(),
                .keyword_import => try self.importDecl(&imports),
                .keyword_alias => {
                    if (try self.aliasDecl()) |declaration| {
                        try aliases.append(self.arena, declaration);
                    } else {
                        self.recover();
                    }
                },
                .keyword_struct, .keyword_class => {
                    if (try self.structDecl()) |declaration| {
                        try structs.append(self.arena, declaration);
                    } else {
                        self.recover();
                    }
                },
                .keyword_interface => {
                    if (try self.interfaceDecl()) |declaration| {
                        try interfaces.append(self.arena, declaration);
                    } else {
                        self.recover();
                    }
                },
                .keyword_enum => {
                    if (try self.enumDecl()) |declaration| {
                        try enums.append(self.arena, declaration);
                    } else {
                        self.recover();
                    }
                },
                .keyword_union => {
                    if (try self.unionDecl(false)) |declaration| {
                        try unions.append(self.arena, declaration);
                    } else {
                        self.recover();
                    }
                },
                .keyword_mutating => {
                    try self.report(
                        "luce.parse.mutating",
                        self.peek().span,
                        "mutating belongs on an interface requirement; concrete methods infer receiver mutation from their body",
                        .{},
                    );
                    self.recover();
                },
                .keyword_func => {
                    if (try self.funcDecl()) |declaration| {
                        try functions.append(self.arena, declaration);
                    } else {
                        self.recover();
                    }
                },
                .keyword_extern => {
                    if (self.atExternType()) {
                        if (try self.externTypeDecl()) |declaration| {
                            try extern_types.append(self.arena, declaration);
                        } else {
                            self.recover();
                        }
                    } else if (self.peekAhead(1) == .keyword_struct) {
                        if (try self.externStructDecl()) |declaration| {
                            try structs.append(self.arena, declaration);
                        } else {
                            self.recover();
                        }
                    } else if (self.peekAhead(1) == .keyword_var) {
                        if (try self.externVarDecl()) |declaration| {
                            try extern_vars.append(self.arena, declaration);
                        } else {
                            self.recover();
                        }
                    } else if (self.peekAhead(1) == .keyword_class) {
                        try self.report(
                            "luce.parse.extern",
                            self.peek().span,
                            "an extern aggregate is a value: write extern struct — C has no reference classes",
                            .{},
                        );
                        self.recover();
                    } else if (try self.externDecl()) |declaration| {
                        try externs.append(self.arena, declaration);
                    } else {
                        self.recover();
                    }
                },
                .keyword_static => {
                    try self.report(
                        "luce.parse.static",
                        self.peek().span,
                        "static belongs before func inside a struct or enum; a file-scope function is already a namespace function",
                        .{},
                    );
                    self.recover();
                },
                // A file-scope binding is a compile-time constant
                // (docs/CONSTANTS.md, LANGUAGE §20.4): `let` is the
                // spec spelling and `const` the older one, both accepted
                // while the tree migrates.  `var` is refused because a
                // module has no mutable globals.
                .keyword_const, .keyword_let => {
                    if (try self.constDecl()) |declaration| {
                        try constants.append(self.arena, declaration);
                    } else {
                        self.recover();
                    }
                },
                .keyword_var => {
                    try self.report(
                        "luce.parse.top",
                        self.peek().span,
                        "a module has no mutable globals; a file-scope binding is a constant — write let or const",
                        .{},
                    );
                    self.recover();
                },
                .keyword_pub => {
                    try self.markedDeclaration(&aliases, &constants, &structs, &interfaces, &enums, &unions, &functions, &extern_types, &extern_vars);
                },
                else => {
                    // A file-scope name is never valid, so a word that
                    // opens a declaration in some *other* language is
                    // the habit rather than a coincidence.  Naming the
                    // Luce spelling beats listing the four keywords.
                    if (self.peekKind() == .identifier) {
                        const word = self.text(self.peek());
                        // `from geo import Point` — the member import.
                        // Contextual, like `as`: no other file-scope
                        // line opens with a bare identifier.
                        if (std.mem.eql(u8, word, "from")) {
                            try self.fromImportDecl(&imports);
                            continue;
                        }
                        if (miscasedKeyword(word)) |keyword| {
                            try self.report(
                                "luce.parse.top",
                                self.peek().span,
                                "keywords are lowercase: write '{s}', not '{s}'",
                                .{ keyword, word },
                            );
                            self.recover();
                            continue;
                        }
                        if (foreignWord(word)) |advice| {
                            try self.report("luce.parse.top", self.peek().span, "{s}", .{advice});
                            self.recover();
                            continue;
                        }
                    }
                    try self.report(
                        "luce.parse.top",
                        self.peek().span,
                        "expected import, alias, const, struct, interface, enum, union, or func at file scope, found {s}",
                        .{try self.found()},
                    );
                    self.recover();
                },
            }
        }
        return .{
            .imports = try imports.toOwnedSlice(self.arena),
            .aliases = try aliases.toOwnedSlice(self.arena),
            .constants = try constants.toOwnedSlice(self.arena),
            .structs = try structs.toOwnedSlice(self.arena),
            .interfaces = try interfaces.toOwnedSlice(self.arena),
            .enums = try enums.toOwnedSlice(self.arena),
            .unions = try unions.toOwnedSlice(self.arena),
            .functions = try functions.toOwnedSlice(self.arena),
            .externs = try externs.toOwnedSlice(self.arena),
            .extern_types = try extern_types.toOwnedSlice(self.arena),
            .extern_vars = try extern_vars.toOwnedSlice(self.arena),
        };
    }

    /// A `pub` marker at file scope, before func, const, alias, struct,
    /// interface, enum, or union — and nowhere else (docs/VISIBILITY.md).
    /// The marker parses onto the declaration it fronts; the refusals —
    /// a second `pub`, a marker fronting anything unmarkable — follow.
    fn markedDeclaration(
        self: *Parser,
        aliases: *std.ArrayList(ast.AliasDecl),
        constants: *std.ArrayList(ast.ConstDecl),
        structs: *std.ArrayList(ast.StructDecl),
        interfaces: *std.ArrayList(ast.InterfaceDecl),
        enums: *std.ArrayList(ast.EnumDecl),
        unions: *std.ArrayList(ast.UnionDecl),
        functions: *std.ArrayList(ast.FuncDecl),
        extern_types: *std.ArrayList(ast.ExternTypeDecl),
        extern_vars: *std.ArrayList(ast.ExternVarDecl),
    ) Error!void {
        const marker = self.advance();
        const visibility: ast.Visibility = .public;
        if (self.atIndirectUnion()) {
            if (try self.indirectUnion()) |declaration| {
                var marked = declaration;
                marked.visibility = visibility;
                try unions.append(self.arena, marked);
            } else {
                self.recover();
            }
            return;
        }
        switch (self.peekKind()) {
            .colon => {
                try self.report(
                    "luce.parse.top",
                    .{ .start = marker.span.start, .end = self.peek().span.end },
                    "`pub` marks one declaration; write it before each name, not as a region",
                    .{},
                );
                _ = self.advance(); // the colon
                // The body is ordinary declarations that happen to be
                // indented: consume the layout tokens and let the
                // program loop read them at file scope, private — the
                // marker is what was wrong, not the declarations under it.
                if (self.peekKind() == .newline) _ = self.advance();
                if (self.peekKind() == .indent) _ = self.advance();
            },
            .keyword_pub => {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "one `pub` per declaration",
                    .{},
                );
                self.recover();
            },
            .keyword_func => {
                if (try self.funcDecl()) |declaration| {
                    var marked = declaration;
                    marked.visibility = visibility;
                    try functions.append(self.arena, marked);
                } else {
                    self.recover();
                }
            },
            .keyword_static => {
                try self.report(
                    "luce.parse.static",
                    self.peek().span,
                    "static belongs before func inside a struct or enum; a file-scope function is already a namespace function",
                    .{},
                );
                self.recover();
            },
            // `pub let` / `pub const` — an exported file-scope constant
            // (docs/CONSTANTS.md, LANGUAGE §20.4); both spellings while
            // the tree migrates.
            .keyword_const, .keyword_let => {
                if (try self.constDecl()) |declaration| {
                    var marked = declaration;
                    marked.visibility = visibility;
                    try constants.append(self.arena, marked);
                } else {
                    self.recover();
                }
            },
            .keyword_alias => {
                if (try self.aliasDecl()) |declaration| {
                    var marked = declaration;
                    marked.visibility = visibility;
                    try aliases.append(self.arena, marked);
                } else {
                    self.recover();
                }
            },
            .keyword_var => {
                try self.report(
                    "luce.parse.top",
                    self.peek().span,
                    "a module has no mutable globals; a file-scope binding is a constant — write let or const",
                    .{},
                );
                self.recover();
            },
            .keyword_struct, .keyword_class => {
                if (try self.structDecl()) |declaration| {
                    var marked = declaration;
                    marked.visibility = visibility;
                    try structs.append(self.arena, marked);
                } else {
                    self.recover();
                }
            },
            .keyword_interface => {
                if (try self.interfaceDecl()) |declaration| {
                    var marked = declaration;
                    marked.visibility = visibility;
                    try interfaces.append(self.arena, marked);
                } else {
                    self.recover();
                }
            },
            .keyword_enum => {
                if (try self.enumDecl()) |declaration| {
                    var marked = declaration;
                    marked.visibility = visibility;
                    try enums.append(self.arena, marked);
                } else {
                    self.recover();
                }
            },
            .keyword_union => {
                if (try self.unionDecl(false)) |declaration| {
                    var marked = declaration;
                    marked.visibility = visibility;
                    try unions.append(self.arena, marked);
                } else {
                    self.recover();
                }
            },
            .keyword_mutating => {
                try self.report(
                    "luce.parse.mutating",
                    self.peek().span,
                    "mutating belongs on an interface requirement; concrete methods infer receiver mutation from their body",
                    .{},
                );
                self.recover();
            },
            // `pub extern type Name`, `pub extern struct Name:`, and
            // `pub extern var name: T` — a handle, a C-layout struct,
            // and a C global are declarations and take the marker like
            // any other (docs/FFI.md).  An extern *function* stays
            // unmarkable, exactly as it was before handles arrived,
            // and earns the sentence below.
            .keyword_extern => {
                if (self.atExternType()) {
                    if (try self.externTypeDecl()) |declaration| {
                        var marked = declaration;
                        marked.visibility = visibility;
                        try extern_types.append(self.arena, marked);
                    } else {
                        self.recover();
                    }
                } else if (self.peekAhead(1) == .keyword_struct) {
                    if (try self.externStructDecl()) |declaration| {
                        var marked = declaration;
                        marked.visibility = visibility;
                        try structs.append(self.arena, marked);
                    } else {
                        self.recover();
                    }
                } else if (self.peekAhead(1) == .keyword_var) {
                    if (try self.externVarDecl()) |declaration| {
                        var marked = declaration;
                        marked.visibility = visibility;
                        try extern_vars.append(self.arena, marked);
                    } else {
                        self.recover();
                    }
                } else {
                    try self.report(
                        "luce.parse.top",
                        marker.span,
                        "'{s}' marks a declaration: expected func, alias, const, struct, interface, enum, union, or an extern type, struct, or var after it, found {s}",
                        .{ keywordWord(marker.kind).?, try self.found() },
                    );
                    self.recover();
                }
            },
            else => {
                try self.report(
                    "luce.parse.top",
                    marker.span,
                    "'{s}' marks a declaration: expected func, alias, const, struct, interface, enum, or union after it, found {s}",
                    .{ keywordWord(marker.kind).?, try self.found() },
                );
                self.recover();
            },
        }
    }

    const ImportPath = struct {
        name: []const u8,
        last: Token,
        origin: source_mod.Origin,
    };

    /// The module path both import forms share: a sibling name,
    /// `std.name`, or a dotted project path (docs/PACKAGES.md D2,
    /// resolved by the host).  `std` is the one namespace the grammar
    /// knows, and *what* it contains is stage 1's to say.
    fn importPath(self: *Parser, after: []const u8) Error!?ImportPath {
        const head = (try self.expect(.identifier, after)) orelse return null;
        var name = self.text(head);
        var last = head;
        var origin: source_mod.Origin = .sibling;
        if (std.mem.eql(u8, name, source_mod.standard_namespace) and self.peekKind() == .dot) {
            _ = self.advance(); // dot
            last = (try self.expect(.identifier, "a standard module name after std.")) orelse return null;
            name = self.text(last);
            origin = .standard;
            // import std.a.b — the namespace is one level deep.
            if (self.peekKind() == .dot) {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "'import {s}.{s}' names one standard module: there are no deeper paths",
                    .{ source_mod.standard_namespace, name },
                );
                return null;
            }
        } else while (self.peekKind() == .dot) {
            // import a.b maps dots to folders under the project root;
            // the path is rebuilt because a dot may carry spaces.
            _ = self.advance(); // dot
            last = (try self.expect(.identifier, "a module name after the dot")) orelse return null;
            name = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ name, self.text(last) });
        }
        return .{ .name = name, .last = last, .origin = origin };
    }

    /// import name — the sibling module `name.luc`; import std.name —
    /// the standard library's; import a.b — the file b.luc in folder
    /// a under the project root.  An optional trailing `as name` picks
    /// the binding; `as` is read contextually — after the module path
    /// only an alias can follow, so the word stays an ordinary
    /// identifier everywhere else.
    fn importDecl(self: *Parser, imports: *std.ArrayList(ast.Import)) Error!void {
        const start = self.advance(); // import
        const path = (try self.importPath("a module name after import")) orelse {
            self.recover();
            return;
        };
        const name = path.name;
        const last = path.last;
        const origin = path.origin;
        var bound = self.text(last);
        var end = last.span.end;
        if (self.peekKind() == .identifier and std.mem.eql(u8, self.text(self.peek()), "as")) {
            _ = self.advance(); // as
            const alias = (try self.expect(.identifier, "a binding name after as")) orelse {
                self.recover();
                return;
            };
            if (origin == .standard) {
                // The library's names are part of the language surface
                // — `s.split(",")` routes to std.strings by that name —
                // so a standard module keeps its own binding, and the
                // import that collides with it is the one to alias.
                try self.report(
                    "luce.parse.expected",
                    alias.span,
                    "a standard module keeps its name: import {s}.{s} always binds {s}; " ++
                        "alias the import that collides with it instead",
                    .{ source_mod.standard_namespace, name, name },
                );
                self.recover();
                return;
            }
            try self.refuseWildcardName(alias);
            bound = self.text(alias);
            end = alias.span.end;
        }
        try self.endOfStatement("end of line after the import");
        try imports.append(self.arena, .{
            .name = name,
            .binding = bound,
            .origin = origin,
            .span = .{ .start = start.span.start, .end = end },
        });
    }

    /// from geo import Point, length as len — a member import.  The
    /// module loads exactly as `import geo` loads it, but what this
    /// file gains is the named members, bound bare; the module
    /// namespace itself stays unbound.  `from` is contextual the way
    /// `as` is: a file-scope line opening with a bare identifier is
    /// never anything else, so the word costs no keyword.
    fn fromImportDecl(self: *Parser, imports: *std.ArrayList(ast.Import)) Error!void {
        const start = self.advance(); // from
        const path = (try self.importPath("a module name after from")) orelse {
            self.recover();
            return;
        };
        if (self.peekKind() != .keyword_import) {
            try self.report(
                "luce.parse.expected",
                self.peek().span,
                "'from {s}' names members: write 'from {s} import Name'",
                .{ path.name, path.name },
            );
            self.recover();
            return;
        }
        _ = self.advance(); // import
        var members: std.ArrayList(ast.ImportMember) = .empty;
        defer members.deinit(self.arena);
        var end = path.last.span.end;
        while (true) {
            if (self.peekKind() == .star) {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "there is no wildcard import: name each member, or write 'import {s}'",
                    .{path.name},
                );
                self.recover();
                return;
            }
            const member = (try self.expect(.identifier, "a member name after import")) orelse {
                self.recover();
                return;
            };
            try self.refuseWildcardName(member);
            var bound = self.text(member);
            end = member.span.end;
            if (self.peekKind() == .identifier and std.mem.eql(u8, self.text(self.peek()), "as")) {
                _ = self.advance(); // as
                const alias = (try self.expect(.identifier, "a binding name after as")) orelse {
                    self.recover();
                    return;
                };
                try self.refuseWildcardName(alias);
                bound = self.text(alias);
                end = alias.span.end;
            }
            try members.append(self.arena, .{
                .name = self.text(member),
                .binding = bound,
                .span = .{ .start = member.span.start, .end = end },
            });
            if (self.accept(.comma) == null) break;
        }
        try self.endOfStatement("end of line after the import");
        try imports.append(self.arena, .{
            .name = path.name,
            .binding = self.text(path.last),
            .origin = path.origin,
            .members = try members.toOwnedSlice(self.arena),
            .span = .{ .start = start.span.start, .end = end },
        });
    }

    /// A declared name may not be the bare `_`.  The
    /// wildcard has exactly one home — array-shape position, where the
    /// type parser recognises it — and the sentence teaches that one
    /// place.  The declaration still parses under the refused name, so
    /// the rest of the line gets its say and one mistake is one message.
    pub fn refuseWildcardName(self: *Parser, item: Token) Error!void {
        if (!std.mem.eql(u8, self.text(item), "_")) return;
        try self.report(
            "luce.parse.expected",
            item.span,
            "_ is the array-shape wildcard, not a name (array[i64, _]); a binding needs a name",
            .{},
        );
    }

    // -- declarations: constants, types, structs --------------------------

    /// `alias Name = Type` at file scope.  The parser records the written
    /// target; stage 4 resolves chains, imports, privacy, and cycles.
    fn aliasDecl(self: *Parser) Error!?ast.AliasDecl {
        const start = self.advance(); // alias
        const name = (try self.expect(.identifier, "an alias name")) orelse return null;
        try self.refuseWildcardName(name);
        if ((try self.expect(.assign, "'=' with the aliased type")) == null) return null;
        const target = (try self.typeName()) orelse return null;
        try self.endOfStatement("end of line after the alias");
        return .{
            .name = self.text(name),
            .name_span = name.span,
            .target = target,
            .span = .{ .start = start.span.start, .end = target.span.end },
        };
    }

    /// const name = value at file scope — a constant declaration.
    fn constDecl(self: *Parser) Error!?ast.ConstDecl {
        const start = self.advance(); // const
        const name = (try self.expect(.identifier, "a constant name")) orelse return null;
        try self.refuseWildcardName(name);
        var annotation: ?ast.TypeName = null;
        if (self.accept(.colon) != null) {
            annotation = (try self.typeName()) orelse return null;
        }
        if ((try self.expect(.assign, "'=' with the constant's value")) == null) return null;
        const value = (try self.expression()) orelse return null;
        try self.endOfStatement("end of line after the constant");
        return .{
            .name = self.text(name),
            .name_span = name.span,
            .annotation = annotation,
            .value = value,
            .span = .{ .start = start.span.start, .end = value.span().end },
        };
    }

    pub fn typeName(self: *Parser) Error!?ast.TypeName {
        return self.typeNameBeforeCall(false);
    }

    /// The type following `new`. A following `(` belongs to construction
    /// values, not to the type, so this one stopping point differs from an
    /// ordinary annotation. Recursive type arguments still use `typeName`
    /// and therefore reject parenthesized container application.
    pub fn constructionTypeName(self: *Parser) Error!?ast.TypeName {
        return self.typeNameBeforeCall(true);
    }

    fn typeNameBeforeCall(self: *Parser, construction: bool) Error!?ast.TypeName {
        if (!try self.enter("type")) return null;
        defer self.leave();

        if (self.peekKind() == .left_paren) return self.parenthesizedTypeName();
        if (self.peekKind() == .keyword_func) return self.functionTypeName();
        // `cfunc(T, ...) -> R` — the C function pointer type
        // (docs/FFI.md).  A contextual spelling, not a keyword: it is
        // recognized only with its parentheses, a shape that was
        // previously a parse error in type position, so a program
        // remains free to name its own type `cfunc`.
        if (self.peekKind() == .identifier and
            self.peekAhead(1) == .left_paren and
            std.mem.eql(u8, self.text(self.peek()), "cfunc"))
        {
            return self.cfuncTypeName();
        }
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
        if (self.peekKind() == .left_paren) {
            if (construction) return self.optionalSuffix(written);
            try self.report(
                "luce.parse.type",
                self.peek().span,
                "type arguments use brackets: write {s}[...]",
                .{written.name},
            );
            return null;
        }
        if (self.peekKind() != .left_bracket) return self.optionalSuffix(written);
        const opener = self.advance(); // [

        // `task[...]` holds a **return shape**, not a type: what stands
        // inside is written exactly as it would be after `->`, because
        // that is what it names (docs/THREADS.md).  So `task[f64!]`
        // and `task[!]` are spelled the way `-> f64!` and `-> !`
        // are, and a bare `task` is a worker that answers nothing and
        // cannot fail.  Nothing else in the grammar takes a `!` here,
        // which is why this arm is by name rather than by shape.
        if (std.mem.eql(u8, written.name, "task")) {
            if (self.accept(.bang)) |marker| {
                written.fallible = true;
                const closing = (try self.expectClose(.right_bracket, opener)) orelse return null;
                _ = marker;
                written.span = .{ .start = item.span.start, .end = closing.span.end };
                return self.optionalSuffix(written);
            }
            const answered = (try self.typeName()) orelse return null;
            written.fallible = self.accept(.bang) != null;
            const closing = (try self.expectClose(.right_bracket, opener)) orelse return null;
            const held = try self.arena.alloc(ast.TypeName, 1);
            held[0] = answered;
            written.arguments = held;
            written.span = .{ .start = item.span.start, .end = closing.span.end };
            return self.optionalSuffix(written);
        }

        var arguments: std.ArrayList(ast.TypeName) = .empty;
        defer arguments.deinit(self.arena);
        var wildcards: u8 = 0;
        var previous_end = opener.span.end;
        while (!expr.endsList(self.peekKind(), .right_bracket)) {
            if (self.peekKind() == .identifier and std.mem.eql(u8, self.text(self.peek()), "_")) {
                const wildcard = self.advance();
                if (wildcards == 255) {
                    try self.report("luce.parse.type", wildcard.span, "too many array dimensions", .{});
                    return null;
                }
                wildcards += 1;
                previous_end = wildcard.span.end;
            } else {
                if (wildcards != 0) {
                    try self.report(
                        "luce.parse.type",
                        self.peek().span,
                        "array rank wildcards come last: array[i64, _, _]",
                        .{},
                    );
                    return null;
                }
                const argument = (try self.typeName()) orelse return null;
                try arguments.append(self.arena, argument);
                previous_end = argument.span.end;
            }
            if (self.accept(.comma) == null) break;
        }
        if (try self.missingSeparator(previous_end)) return null;
        const closing = (try self.expectClose(.right_bracket, opener)) orelse return null;
        written.arguments = try arguments.toOwnedSlice(self.arena);
        written.wildcards = wildcards;
        written.span = .{ .start = item.span.start, .end = closing.span.end };
        return self.optionalSuffix(written);
    }

    /// `(T)` — a parenthesized type is that type.
    ///
    /// **One rule, everywhere a type may stand**, rather than a rule
    /// that fires only where it disambiguates: a reader then never has
    /// to learn where parentheses are permitted, and `(i64)` is legal
    /// and says nothing extra, which is the whole price of having no
    /// special case (SOFTWARE_DESIGN.md §26).
    ///
    /// It exists because a function type's result consumes its own `?`:
    /// `func(i64) -> str?` already means *a function answering a
    /// `str?`*, and it must keep meaning that, because that is how
    /// `parse_i64` is written as a value.  So the only way to say "a
    /// function that may be absent" is to close the function type
    /// before the `?` reaches it — `(func(i64) -> str)?`, which is
    /// Swift's answer and the storable shape of every function value
    /// (docs/BINDING.md D7).
    ///
    /// A comma inside is the *other* thing parentheses spell in this
    /// language, a return shape, and a return shape is not a type
    /// (docs/RETURNS.md) — so the arity is what tells the two apart,
    /// and it is the only thing that can.
    fn parenthesizedTypeName(self: *Parser) Error!?ast.TypeName {
        const opener = self.advance(); // (
        const inner = (try self.typeName()) orelse return null;
        if (self.peekKind() == .comma) {
            try self.report(
                "luce.parse.type",
                .{ .start = opener.span.start, .end = self.peek().span.end },
                "a return shape is not a type: a pair that travels together is a struct",
                .{},
            );
            return null;
        }
        const closing = (try self.expectClose(.right_paren, opener)) orelse return null;
        var written = inner;
        written.span = .{ .start = opener.span.start, .end = closing.span.end };
        if (!try self.refuseSecondQuestion(written)) return null;
        return self.optionalSuffix(written);
    }

    /// A `?` written *inside* the parentheses has already taken the one
    /// level of absence there is, so a second outside them is `T??` —
    /// the same refusal `optionalSuffix` makes of two adjacent ones,
    /// which cannot see this one because a `)` stands between them.
    ///
    /// True when nothing was wrong.
    fn refuseSecondQuestion(self: *Parser, inner: ast.TypeName) Error!bool {
        if (!inner.optional or self.peekKind() != .question) return true;
        try self.report(
            "luce.parse.type",
            self.peek().span,
            "one '?' is all there is: a value is absent or it is not",
            .{},
        );
        return false;
    }

    /// `func(T, ...) -> R` — a function type, spelled the way a
    /// signature already reads (docs/FUNCTIONS.md S2).
    ///
    /// **Parameter types, and no parameter names.**  A name in a
    /// declaration is documentation the call site can use; in a type it
    /// is documentation nothing reads, and a grammar that admits it has
    /// to say what `func(i64)` means — the type `i64` or a parameter
    /// called `i64`.
    fn functionTypeName(self: *Parser) Error!?ast.TypeName {
        const start = self.advance(); // func
        const opener = (try self.expect(.left_paren, "'(' with the parameter types")) orelse return null;
        var parameters: std.ArrayList(ast.TypeName) = .empty;
        defer parameters.deinit(self.arena);
        var previous_end = opener.span.end;
        while (!expr.endsList(self.peekKind(), .right_paren)) {
            const parameter = (try self.typeName()) orelse return null;
            try parameters.append(self.arena, parameter);
            previous_end = parameter.span.end;
            if (self.accept(.comma) == null) break;
        }
        if (try self.missingSeparator(previous_end)) return null;
        const closing = (try self.expectClose(.right_paren, opener)) orelse return null;
        var written: ast.TypeName = .{
            .name = "func",
            .arguments = try parameters.toOwnedSlice(self.arena),
            .span = .{ .start = start.span.start, .end = closing.span.end },
        };
        if (self.accept(.arrow) != null) {
            // `-> !` and `-> T!` say a function value may fail
            // (docs/ERRORS.md R3): the fallibility is part of the
            // type, and a call through the value owes `try` or
            // `catch` exactly as a direct call does.
            if (self.accept(.bang)) |marked| {
                written.fallible = true;
                written.span = .{ .start = start.span.start, .end = marked.span.end };
                try self.functionErrorType(&written, start);
                return self.optionalSuffix(written);
            }
            const answered = (try self.typeName()) orelse return null;
            const held = try self.arena.create(ast.TypeName);
            held.* = answered;
            written.result = held;
            written.span = .{ .start = start.span.start, .end = answered.span.end };
            if (self.accept(.bang)) |marked| {
                written.fallible = true;
                written.span = .{ .start = start.span.start, .end = marked.span.end };
                try self.functionErrorType(&written, start);
            }
        }
        return self.optionalSuffix(written);
    }

    /// `cfunc(T, ...) -> R` — a C function pointer type, spelled the
    /// way a function type is (docs/FFI.md).  The differences are the
    /// boundary's: no `!`, because C has no error channel — a fallible
    /// crossing is a wrapper's business — and the vocabulary of the
    /// parts is stage 4's ruling, not the grammar's.
    fn cfuncTypeName(self: *Parser) Error!?ast.TypeName {
        const start = self.advance(); // the contextual word `cfunc`
        const opener = (try self.expect(.left_paren, "'(' with the parameter types")) orelse return null;
        var parameters: std.ArrayList(ast.TypeName) = .empty;
        defer parameters.deinit(self.arena);
        var previous_end = opener.span.end;
        while (!expr.endsList(self.peekKind(), .right_paren)) {
            const parameter = (try self.typeName()) orelse return null;
            try parameters.append(self.arena, parameter);
            previous_end = parameter.span.end;
            if (self.accept(.comma) == null) break;
        }
        if (try self.missingSeparator(previous_end)) return null;
        const closing = (try self.expectClose(.right_paren, opener)) orelse return null;
        var written: ast.TypeName = .{
            .name = "cfunc",
            .cfunc = true,
            .arguments = try parameters.toOwnedSlice(self.arena),
            .span = .{ .start = start.span.start, .end = closing.span.end },
        };
        if (self.accept(.arrow) != null) {
            if (self.peekKind() == .bang) {
                try self.report(
                    "luce.parse.type",
                    self.peek().span,
                    "a cfunc has no error channel: C answers a value, and a fallible crossing is a wrapper's business (docs/FFI.md)",
                    .{},
                );
                return null;
            }
            const answered = (try self.typeName()) orelse return null;
            const held = try self.arena.create(ast.TypeName);
            held.* = answered;
            written.result = held;
            written.span = .{ .start = start.span.start, .end = answered.span.end };
        }
        if (self.peekKind() == .bang) {
            try self.report(
                "luce.parse.type",
                self.peek().span,
                "a cfunc has no error channel: C answers a value, and a fallible crossing is a wrapper's business (docs/FFI.md)",
                .{},
            );
            return null;
        }
        return self.optionalSuffix(written);
    }

    /// A trailing `?` makes the type just parsed optional.  A second
    /// one is refused here rather than resolved away: `T??` says the
    /// absence itself might be absent, which is a distinction no
    /// program has ever needed and every language that shipped it
    /// regrets (docs/FAILURE.md).
    fn optionalSuffix(self: *Parser, base: ast.TypeName) Error!?ast.TypeName {
        const marker = self.accept(.question) orelse return base;
        var written = base;
        written.optional = true;
        written.span = .{ .start = base.span.start, .end = marker.span.end };
        if (self.peekKind() == .question) {
            try self.report(
                "luce.parse.type",
                self.peek().span,
                "one '?' is all there is: a value is absent or it is not",
                .{},
            );
            return null;
        }
        return written;
    }

    fn structDecl(self: *Parser) Error!?ast.StructDecl {
        const start = self.advance(); // struct or class
        const kind: ast.TypeKind = if (start.kind == .keyword_class) .reference else .value;
        const name = (try self.expect(.identifier, "a struct name")) orelse return null;
        try self.refuseWildcardName(name);
        var interfaces: std.ArrayList(ast.TypeName) = .empty;
        defer interfaces.deinit(self.arena);
        // A plain struct ends its header with `:`.  When a name follows
        // that first colon, it is the explicit-conformance list and a
        // second colon opens the body: `struct Button: Clickable:`.
        if (self.accept(.colon) != null) {
            if (self.peekKind() != .newline) {
                while (true) {
                    const contract = (try self.typeName()) orelse return null;
                    try interfaces.append(self.arena, contract);
                    if (self.accept(.comma) == null) break;
                }
                if ((try self.expect(.colon, "':' after the interface list")) == null) return null;
            }
        } else {
            try self.expected("':' after the struct name");
            // Keep reading when the layout makes the intended body
            // unambiguous.  This mirrors function-header recovery: the
            // missing colon is one diagnostic, while mistakes in the
            // orphaned fields still belong to the reader and should be
            // reported at their own locations.
            if (self.peekKind() != .newline or self.peekAhead(1) != .indent) return null;
        }
        if ((try self.expect(.newline, "end of line after ':'")) == null) return null;
        if ((try self.blockBody("struct")) == null) return null;

        var fields: std.ArrayList(ast.Field) = .empty;
        defer fields.deinit(self.arena);
        var functions: std.ArrayList(ast.FuncDecl) = .empty;
        defer functions.deinit(self.arena);
        var initializer: ?ast.FuncDecl = null;
        var deinitializer: ?ast.FuncDecl = null;
        while (self.peekKind() != .dedent and self.peekKind() != .end_of_file) {
            if (self.accept(.newline) != null) continue;
            if (self.peekKind() == .indent) {
                try self.unexpectedIndent();
                continue;
            }
            if (self.peekKind() == .keyword_pub) {
                if (self.peekAhead(1) == .colon) {
                    try self.report(
                        "luce.parse.expected",
                        self.peek().span,
                        "`pub` marks one member; write it before each name, not as a region",
                        .{},
                    );
                    self.recover();
                    continue;
                }
                _ = self.advance();
                if (self.peekKind() == .keyword_pub) {
                    try self.report(
                        "luce.parse.expected",
                        self.peek().span,
                        "one `pub` per declaration",
                        .{},
                    );
                    self.recover();
                    continue;
                }
                try self.structMember(&fields, &functions, &initializer, &deinitializer, .public);
                continue;
            }
            try self.structMember(&fields, &functions, &initializer, &deinitializer, .private);
        }
        _ = self.accept(.dedent);
        return .{
            .name = self.text(name),
            .name_span = name.span,
            .fields = try fields.toOwnedSlice(self.arena),
            .functions = try functions.toOwnedSlice(self.arena),
            .initializer = initializer,
            .deinitializer = deinitializer,
            .interfaces = try interfaces.toOwnedSlice(self.arena),
            .kind = kind,
            .span = .{ .start = start.span.start, .end = name.span.end },
        };
    }

    /// `interface Name:` followed by declaration-only method signatures.
    /// Bodies are deliberately not accepted: an interface describes the
    /// call surface, while the implementing struct owns the code.
    fn interfaceDecl(self: *Parser) Error!?ast.InterfaceDecl {
        const start = self.advance(); // interface
        const name = (try self.expect(.identifier, "an interface name")) orelse return null;
        try self.refuseWildcardName(name);
        if (!try self.colonOrLayout("':' after the interface name")) return null;
        if ((try self.expect(.newline, "end of line after ':'")) == null) return null;
        if ((try self.blockBody("interface")) == null) return null;

        var methods: std.ArrayList(ast.InterfaceMethod) = .empty;
        defer methods.deinit(self.arena);
        while (self.peekKind() != .dedent and self.peekKind() != .end_of_file) {
            if (self.accept(.newline) != null) continue;
            if (self.peekKind() == .indent) {
                try self.unexpectedIndent();
                continue;
            }
            const mutating = self.accept(.keyword_mutating) != null;
            if (mutating and self.peekKind() == .keyword_mutating) {
                try self.report(
                    "luce.parse.mutating",
                    self.peek().span,
                    "write 'mutating' once before the interface requirement",
                    .{},
                );
                self.recover();
                continue;
            }
            if (self.peekKind() != .keyword_func) {
                try self.report(
                    "luce.parse.interface",
                    self.peek().span,
                    "an interface contains method signatures: write 'func name(...) -> type' or 'mutating func name(...) -> type'",
                    .{},
                );
                self.recover();
                continue;
            }
            const method_start = self.advance();
            const method_name = (try self.expect(.identifier, "an interface method name")) orelse {
                self.recover();
                continue;
            };
            try self.refuseWildcardName(method_name);
            const opener = (try self.expect(.left_paren, "'(' opening the parameter list")) orelse {
                self.recover();
                continue;
            };
            var parameters: std.ArrayList(ast.Parameter) = .empty;
            defer parameters.deinit(self.arena);
            var previous_end = opener.span.end;
            while (!expr.endsList(self.peekKind(), .right_paren)) {
                if (self.peekKind() == .keyword_self or
                    (self.peekKind() == .keyword_var and self.peekAhead(1) == .keyword_self))
                {
                    const receiver_start = self.peek();
                    _ = self.accept(.keyword_var);
                    const receiver = self.advance();
                    try self.report(
                        "luce.parse.self",
                        .{ .start = receiver_start.span.start, .end = receiver.span.end },
                        "self is implied in an interface method; remove the parameter",
                        .{},
                    );
                    self.recover();
                    break;
                }
                if (self.peekKind() == .keyword_var) {
                    const marker = self.advance();
                    try self.report(
                        "luce.parse.self",
                        marker.span,
                        "parameters are values and never var; use a local var or return the updated value",
                        .{},
                    );
                    self.recover();
                    break;
                }
                const parameter_name = (try self.expect(.identifier, "a parameter name")) orelse {
                    self.recover();
                    break;
                };
                try self.refuseWildcardName(parameter_name);
                if ((try self.expect(.colon, "':' after the parameter name")) == null) {
                    self.recover();
                    break;
                }
                const parameter_type = (try self.typeName()) orelse {
                    self.recover();
                    break;
                };
                var default_value: ?*ast.Expression = null;
                var written_end = parameter_type.span.end;
                if (self.accept(.assign) != null) {
                    const written = (try self.expression()) orelse {
                        self.recover();
                        break;
                    };
                    default_value = written;
                    written_end = written.span().end;
                    try self.report(
                        "luce.parse.interface",
                        written.span(),
                        "interface methods cannot declare defaults; put the default on the implementation or at the call site",
                        .{},
                    );
                }
                try parameters.append(self.arena, .{
                    .name = self.text(parameter_name),
                    .name_span = parameter_name.span,
                    .type_name = parameter_type,
                    .default = default_value,
                    .span = .{ .start = parameter_name.span.start, .end = written_end },
                });
                previous_end = written_end;
                if (self.accept(.comma) == null) break;
            }
            if (try self.missingSeparator(previous_end)) return null;
            if ((try self.expectClose(.right_paren, opener)) == null) {
                self.recover();
                continue;
            }
            var returns: std.ArrayList(ast.TypeName) = .empty;
            defer returns.deinit(self.arena);
            var fallible = false;
            var method_end = method_name.span.end;
            if (self.accept(.arrow) != null) {
                if (self.peekKind() == .left_paren) {
                    if (!try self.returnShape(&returns)) return null;
                    method_end = returns.items[returns.items.len - 1].span.end;
                } else if (self.peekKind() != .bang) {
                    const only = (try self.typeName()) orelse return null;
                    method_end = only.span.end;
                    try returns.append(self.arena, only);
                }
                fallible = self.accept(.bang) != null;
            }
            try self.endOfStatement("end of line after the interface method");
            try methods.append(self.arena, .{
                .name = self.text(method_name),
                .name_span = method_name.span,
                .parameters = try parameters.toOwnedSlice(self.arena),
                .returns = try returns.toOwnedSlice(self.arena),
                .mutating = mutating,
                .fallible = fallible,
                .span = .{ .start = method_start.span.start, .end = method_end },
            });
        }
        _ = self.accept(.dedent);
        return .{
            .name = self.text(name),
            .name_span = name.span,
            .methods = try methods.toOwnedSlice(self.arena),
            .span = .{ .start = start.span.start, .end = name.span.end },
        };
    }

    /// One struct member — a function or a field — carrying `visibility`:
    /// `.public` when `pub` fronts it, `.private` for the unmarked default
    /// (docs/VISIBILITY.md).
    fn structMember(
        self: *Parser,
        fields: *std.ArrayList(ast.Field),
        functions: *std.ArrayList(ast.FuncDecl),
        initializer: *?ast.FuncDecl,
        deinitializer: *?ast.FuncDecl,
        visibility: ast.Visibility,
    ) Error!void {
        // Classes are final. Keep the tempting inheritance spelling from
        // turning into a confusing "field named override" diagnostic: there
        // is no override dispatch, `super`, or subclassing in Luce. Explicit
        // interfaces are the only polymorphic method surface.
        if (self.peekKind() == .identifier and
            std.mem.eql(u8, self.text(self.peek()), "override") and
            (self.peekAhead(1) == .keyword_func or self.peekAhead(1) == .keyword_static))
        {
            const marker = self.advance();
            try self.report(
                "luce.parse.override",
                marker.span,
                "classes are final: method overrides and inheritance are not supported; use an interface or composition",
                .{},
            );
            self.recover();
            return;
        }
        const weak_marker = self.accept(.keyword_weak);
        if (self.peekKind() == .keyword_mutating) {
            const marker = self.advance();
            try self.report(
                "luce.parse.mutating",
                marker.span,
                "mutating belongs on an interface requirement; concrete methods infer receiver mutation from their body",
                .{},
            );
            self.recover();
            return;
        }
        if (weak_marker != null and
            (self.peekKind() == .keyword_func or
                self.peekKind() == .keyword_static or
                self.peekKind() == .keyword_init or
                self.peekKind() == .keyword_deinit))
        {
            try self.report(
                "luce.parse.weak",
                weak_marker.?.span,
                "weak modifies stored fields, not methods",
                .{},
            );
            self.recover();
            return;
        }
        if (self.peekKind() == .keyword_init) {
            const parsed = (try self.initDecl()) orelse {
                self.recover();
                return;
            };
            if (initializer.* != null) {
                try self.report(
                    "luce.sema.class.lifecycle",
                    parsed.span,
                    "a class may declare init only once",
                    .{},
                );
                return;
            }
            var marked = parsed;
            marked.visibility = visibility;
            initializer.* = marked;
            return;
        }
        if (self.peekKind() == .keyword_deinit) {
            const parsed = (try self.deinitDecl()) orelse {
                self.recover();
                return;
            };
            if (visibility == .public) {
                try self.report(
                    "luce.sema.class.lifecycle",
                    parsed.span,
                    "deinit has no visibility: it is called only by ARC at the class's last strong release",
                    .{},
                );
            }
            if (deinitializer.* != null) {
                try self.report(
                    "luce.sema.class.lifecycle",
                    parsed.span,
                    "a class has one lifetime and may declare deinit only once",
                    .{},
                );
                return;
            }
            deinitializer.* = parsed;
            return;
        }
        if ((self.peekKind() == .keyword_static or self.peekKind() == .keyword_func) and
            (self.peekAhead(1) == .keyword_init or self.peekAhead(1) == .keyword_deinit))
        {
            const marker = self.advance();
            const lifecycle = self.advance();
            const word = if (lifecycle.kind == .keyword_init) "init" else "deinit";
            try self.report(
                "luce.sema.class.lifecycle",
                .{ .start = marker.span.start, .end = lifecycle.span.end },
                "{s} is a class lifecycle body, not a {s}; remove '{s} '",
                .{ word, if (marker.kind == .keyword_static) "static member" else "method", self.text(marker) },
            );
            self.recover();
            return;
        }
        if (self.peekKind() == .keyword_func or self.peekKind() == .keyword_static) {
            const declaration = if (self.peekKind() == .keyword_static)
                try self.staticFuncDecl()
            else
                try self.funcDecl();
            if (declaration) |parsed| {
                var marked = parsed;
                marked.visibility = visibility;
                try functions.append(self.arena, marked);
            } else {
                self.recover();
            }
            return;
        }
        // `let`/`var` in front of a field says whether it may be
        // reassigned after it is first set (docs/VISIBILITY.md §10.1).
        // Bare `x: T` is the transitional spelling, accepted for one
        // release and read as `var`.
        const mutability: ast.FieldMutability = switch (self.peekKind()) {
            .keyword_let => blk: {
                _ = self.advance();
                break :blk .immutable;
            },
            .keyword_var => blk: {
                _ = self.advance();
                break :blk .mutable;
            },
            else => .unspecified,
        };
        const field_name = (try self.expect(.identifier, "a field name")) orelse {
            self.recover();
            return;
        };
        try self.refuseWildcardName(field_name);
        if ((try self.expect(.colon, "':' after the field name")) == null) {
            self.recover();
            return;
        }
        const field_type = (try self.typeName()) orelse {
            self.recover();
            return;
        };
        // `= EXPRESSION` — the field's default, the same clause a
        // parameter takes (docs/ARGS.md D8); stage 4's folder
        // decides what it may be.
        var default_value: ?*ast.Expression = null;
        var written_end = field_type.span.end;
        if (self.accept(.assign) != null) {
            const written = (try self.expression()) orelse {
                self.recover();
                return;
            };
            default_value = written;
            written_end = written.span().end;
        }
        try self.endOfStatement("end of line after the field");
        try fields.append(self.arena, .{
            .name = self.text(field_name),
            .name_span = field_name.span,
            .type_name = field_type,
            .default = default_value,
            .weak = weak_marker != null,
            .mutability = mutability,
            .visibility = visibility,
            .span = .{
                .start = if (weak_marker) |marker| marker.span.start else field_name.span.start,
                .end = written_end,
            },
        });
    }

    /// `init(parameters):` or `init(parameters) -> !:`. The enclosing
    /// class is the implicit successful result; `!` is the only result
    /// marker source may write because it describes failure, not a value.
    fn initDecl(self: *Parser) Error!?ast.FuncDecl {
        const marker = self.advance(); // init
        const opener = (try self.expect(.left_paren, "'(' opening the initializer parameter list")) orelse
            return null;
        const parameters = (try self.parameterList(opener, false)) orelse return null;

        var fallible = false;
        var error_type: ?*ast.TypeName = null;
        if (self.accept(.arrow) != null) {
            if (self.accept(.bang) == null) {
                try self.report(
                    "luce.sema.class.lifecycle",
                    self.peek().span,
                    "init returns the new class implicitly; write '-> !' only when initialization can fail",
                    .{},
                );
                return null;
            }
            fallible = true;
            if (self.peekKind() == .identifier) {
                const failing = (try self.typeName()) orelse return null;
                const held = try self.arena.create(ast.TypeName);
                held.* = failing;
                error_type = held;
            }
        }
        const body = (try self.block("init")) orelse return null;
        return .{
            .name = "init",
            .name_span = marker.span,
            .parameters = parameters,
            .error_type = error_type,
            .fallible = fallible,
            .body = body,
            .span = marker.span,
        };
    }

    /// `deinit:` — deliberately smaller than a function declaration. The
    /// spelling has no parameter list, result, fallibility, visibility, or
    /// callable name; the analyzer later installs its implied class `self`.
    fn deinitDecl(self: *Parser) Error!?ast.FuncDecl {
        const marker = self.advance(); // deinit
        if (self.peekKind() != .colon) {
            try self.report(
                "luce.sema.class.lifecycle",
                .{ .start = marker.span.start, .end = self.peek().span.end },
                "deinit takes no parameters or result: write 'deinit:'",
                .{},
            );
            return null;
        }
        const body = (try self.block("deinit")) orelse return null;
        return .{
            .name = "deinit",
            .name_span = marker.span,
            .parameters = &.{},
            .body = body,
            .span = marker.span,
        };
    }

    // -- declarations: enums ----------------------------------------------

    /// `enum Method:` / `enum Method(u8):` — the declaration form
    /// that mirrors struct's (docs/ENUMS.md D1): a name, an optional
    /// backing width in parentheses, then one indented member per
    /// line, with the methods and namespace functions a struct body
    /// takes (D7).
    ///
    /// A member's `= value` is parsed as an ordinary expression and
    /// folded by stage 4, exactly as a field default is: what the
    /// expression may *be* is the folder's question, so `= 1 << 3` is
    /// a constant and `= f()` is a constant diagnostic.
    fn enumDecl(self: *Parser) Error!?ast.EnumDecl {
        const start = self.advance(); // enum
        const name = (try self.expect(.identifier, "an enum name")) orelse return null;
        try self.refuseWildcardName(name);
        var backing: ?ast.TypeName = null;
        if (self.peekKind() == .left_paren) {
            const opener = self.advance();
            backing = (try self.typeName()) orelse return null;
            if ((try self.expectClose(.right_paren, opener)) == null) return null;
        }
        if (!try self.colonOrLayout("':' after the enum name")) return null;
        if ((try self.expect(.newline, "end of line after ':'")) == null) return null;
        if ((try self.blockBody("enum")) == null) return null;

        var members: std.ArrayList(ast.EnumMember) = .empty;
        defer members.deinit(self.arena);
        var functions: std.ArrayList(ast.FuncDecl) = .empty;
        defer functions.deinit(self.arena);
        while (self.peekKind() != .dedent and self.peekKind() != .end_of_file) {
            if (self.accept(.newline) != null) continue;
            if (self.peekKind() == .indent) {
                try self.unexpectedIndent();
                continue;
            }
            var visibility: ast.Visibility = .private;
            if (self.peekKind() == .keyword_pub) {
                visibility = (try self.enumMarker()) orelse continue;
            }
            if (self.peekKind() == .keyword_func or self.peekKind() == .keyword_static) {
                const declaration = if (self.peekKind() == .keyword_static)
                    try self.staticFuncDecl()
                else
                    try self.funcDecl();
                if (declaration) |parsed| {
                    var marked = parsed;
                    marked.visibility = visibility;
                    try functions.append(self.arena, marked);
                } else {
                    self.recover();
                }
                continue;
            }
            if (try self.enumMember()) |member| {
                try members.append(self.arena, member);
            } else {
                self.recover();
            }
        }
        _ = self.accept(.dedent);
        return .{
            .name = self.text(name),
            .name_span = name.span,
            .backing = backing,
            .members = try members.toOwnedSlice(self.arena),
            .functions = try functions.toOwnedSlice(self.arena),
            .span = .{ .start = start.span.start, .end = name.span.end },
        };
    }

    /// A visibility word inside an enum body.  A function may carry one
    /// — it is a declaration like any other (docs/VISIBILITY.md §5) —
    /// but a *member* may not: an enum's members are what the type is,
    /// and a match arm cannot name one the file it stands in cannot
    /// see.  A region label is the same refusal wearing a colon.
    ///
    /// The visibility carried by a function behind the marker.  A
    /// marker on an enum value is reported and dissolved to `.none` so
    /// the value still parses; null means recovery consumed the line.
    fn enumMarker(self: *Parser) Error!?ast.Visibility {
        const marker = self.advance();
        const word = keywordWord(marker.kind).?;
        if (self.peekKind() == .colon) {
            try self.report(
                "luce.parse.expected",
                .{ .start = marker.span.start, .end = self.peek().span.end },
                "'{s}:' opens a region inside a struct; an enum's members are the type and are always visible",
                .{word},
            );
            _ = self.advance(); // the colon
            self.recover();
            return null;
        }
        if (self.peekKind() == .keyword_pub) {
            try self.report(
                "luce.parse.expected",
                self.peek().span,
                "one visibility word per declaration",
                .{},
            );
            self.recover();
            return null;
        }
        if (self.peekKind() == .keyword_func or self.peekKind() == .keyword_static) {
            return .public;
        }
        try self.report(
            "luce.parse.expected",
            marker.span,
            "an enum member is part of the type and is always visible; write '{s} enum' to withhold the whole set",
            .{word},
        );
        return .private;
    }

    /// One member line: `stored`, or `stored = 8`.
    fn enumMember(self: *Parser) Error!?ast.EnumMember {
        const name = (try self.expect(.identifier, "an enum member name")) orelse return null;
        try self.refuseWildcardName(name);
        // `stored: 8` — the struct field's colon, in the one body that
        // does not take one.  A member is a name and a value, not a
        // name and a type.
        if (self.peekKind() == .colon) {
            try self.report(
                "luce.parse.expected",
                self.peek().span,
                "an enum member takes a value, not a type: write '{s} = 8', or leave it to follow the member above",
                .{self.text(name)},
            );
            return null;
        }
        var value: ?*ast.Expression = null;
        var written_end = name.span.end;
        if (self.accept(.assign) != null) {
            const written = (try self.expression()) orelse return null;
            value = written;
            written_end = written.span().end;
        }
        try self.endOfStatement("end of line after the member");
        return .{
            .name = self.text(name),
            .name_span = name.span,
            .value = value,
            .span = .{ .start = name.span.start, .end = written_end },
        };
    }

    // -- declarations: unions -----------------------------------------------

    /// `union Shape:` — the declaration form that mirrors enum's
    /// (docs/UNION.md D1): a name, then one indented member per line,
    /// each optionally carrying a parenthesized **named** field list,
    /// with the methods and namespace functions a struct body takes
    /// (D17).
    ///
    /// What a union does *not* take, and where each refusal lands: no
    /// backing width and no discriminant in parentheses after the name
    /// (R2 — the enum is declared separately and matched on), no
    /// `= value` on a member (a member is not a number, D1), and no
    /// positional payload (a field is named, always).
    fn unionDecl(self: *Parser, indirect: bool) Error!?ast.UnionDecl {
        const start = self.advance(); // union
        const name = (try self.expect(.identifier, "a union name")) orelse return null;
        try self.refuseWildcardName(name);
        if (self.peekKind() == .left_paren) {
            try self.report(
                "luce.parse.expected",
                self.peek().span,
                "a union names no discriminant: declare the enum on its own and match on it",
                .{},
            );
            return null;
        }
        if (!try self.colonOrLayout("':' after the union name")) return null;
        if ((try self.expect(.newline, "end of line after ':'")) == null) return null;
        if ((try self.blockBody("union")) == null) return null;

        var members: std.ArrayList(ast.UnionMember) = .empty;
        defer members.deinit(self.arena);
        var functions: std.ArrayList(ast.FuncDecl) = .empty;
        defer functions.deinit(self.arena);
        while (self.peekKind() != .dedent and self.peekKind() != .end_of_file) {
            if (self.accept(.newline) != null) continue;
            if (self.peekKind() == .indent) {
                try self.unexpectedIndent();
                continue;
            }
            var visibility: ast.Visibility = .private;
            if (self.peekKind() == .keyword_pub) {
                visibility = (try self.unionMarker()) orelse continue;
            }
            if (self.peekKind() == .keyword_func or self.peekKind() == .keyword_static) {
                const declaration = if (self.peekKind() == .keyword_static)
                    try self.staticFuncDecl()
                else
                    try self.funcDecl();
                if (declaration) |parsed| {
                    var marked = parsed;
                    marked.visibility = visibility;
                    try functions.append(self.arena, marked);
                } else {
                    self.recover();
                }
                continue;
            }
            if (try self.unionMember()) |member| {
                try members.append(self.arena, member);
            } else {
                self.recover();
            }
        }
        _ = self.accept(.dedent);
        return .{
            .name = self.text(name),
            .name_span = name.span,
            .members = try members.toOwnedSlice(self.arena),
            .functions = try functions.toOwnedSlice(self.arena),
            .indirect = indirect,
            .span = .{ .start = start.span.start, .end = name.span.end },
        };
    }

    /// The `! E` a fallible function type may carry (docs/ERRORS.md
    /// R2): a type name straight after the `!`, when one follows.
    fn functionErrorType(self: *Parser, written: *ast.TypeName, start: Token) Error!void {
        if (self.peekKind() != .identifier) return;
        const failing = (try self.typeName()) orelse return;
        const held = try self.arena.create(ast.TypeName);
        held.* = failing;
        written.error_type = held;
        written.span = .{ .start = start.span.start, .end = failing.span.end };
    }

    /// The contextual `indirect` at a declaration position: claimed
    /// only when the very next token is `union`, so the word stays an
    /// ordinary identifier everywhere else (the `blocking` rule).
    fn indirectUnion(self: *Parser) Error!?ast.UnionDecl {
        _ = self.advance(); // indirect
        if (self.peekKind() != .keyword_union) {
            try self.report(
                "luce.parse.expected",
                self.peek().span,
                "'indirect' modifies a union declaration: write 'indirect union NAME:'",
                .{},
            );
            return null;
        }
        return self.unionDecl(true);
    }

    fn atIndirectUnion(self: *const Parser) bool {
        if (self.peekKind() != .identifier) return false;
        if (!std.mem.eql(u8, self.text(self.peek()), "indirect")) return false;
        // Claimed before any declaration keyword — a following union
        // parses, and anything else gets the teaching refusal in
        // `indirectUnion` instead of the generic file-scope sentence.
        return switch (self.tokens[self.index + 1].kind) {
            .keyword_union,
            .keyword_struct,
            .keyword_class,
            .keyword_enum,
            .keyword_interface,
            => true,
            else => false,
        };
    }

    /// A visibility word inside a union body — `enumMarker`'s rule,
    /// one keyword over: a function may carry one, a member may not,
    /// because a union's members are what the type is and a match arm
    /// cannot name one the file it stands in cannot see.
    fn unionMarker(self: *Parser) Error!?ast.Visibility {
        const marker = self.advance();
        const word = keywordWord(marker.kind).?;
        if (self.peekKind() == .colon) {
            try self.report(
                "luce.parse.expected",
                .{ .start = marker.span.start, .end = self.peek().span.end },
                "'{s}:' opens a region inside a struct; a union's members are the type and are always visible",
                .{word},
            );
            _ = self.advance(); // the colon
            self.recover();
            return null;
        }
        if (self.peekKind() == .keyword_pub) {
            try self.report(
                "luce.parse.expected",
                self.peek().span,
                "one visibility word per declaration",
                .{},
            );
            self.recover();
            return null;
        }
        if (self.peekKind() == .keyword_func or self.peekKind() == .keyword_static) {
            return .public;
        }
        try self.report(
            "luce.parse.expected",
            marker.span,
            "a union member is part of the type and is always visible; write '{s} union' to withhold the whole set",
            .{word},
        );
        return .private;
    }

    /// One member line: `null`, or `circle(radius: f64)` — a
    /// snake_case name and an optional parenthesized field list whose
    /// fields are named always and take the default clause a struct
    /// field takes (docs/UNION.md D1, D4).
    fn unionMember(self: *Parser) Error!?ast.UnionMember {
        const name = (try self.expect(.identifier, "a union member name")) orelse return null;
        try self.refuseWildcardName(name);
        // `circle = 1` — an enum habit.  A union member is not a
        // number and has no second identity to assign (D1).
        if (self.peekKind() == .assign) {
            try self.report(
                "luce.parse.expected",
                self.peek().span,
                "a union member holds no number: write '{s}', or '{s}(field: type)' for a payload",
                .{ self.text(name), self.text(name) },
            );
            return null;
        }
        // `circle: f64` — the struct field's colon, in the one body
        // that spells a payload with parentheses.
        if (self.peekKind() == .colon) {
            try self.report(
                "luce.parse.expected",
                self.peek().span,
                "a union member's payload is parenthesized: write '{s}(field: type)'",
                .{self.text(name)},
            );
            return null;
        }
        var fields: std.ArrayList(ast.Field) = .empty;
        defer fields.deinit(self.arena);
        var written_end = name.span.end;
        if (self.peekKind() == .left_paren) {
            const opener = self.advance();
            if (self.peekKind() == .right_paren) {
                try self.report(
                    "luce.parse.expected",
                    .{ .start = opener.span.start, .end = self.peek().span.end },
                    "parentheses mean a payload: name at least one field, or write '{s}' bare",
                    .{self.text(name)},
                );
                return null;
            }
            var previous_end = opener.span.end;
            while (!expr.endsList(self.peekKind(), .right_paren)) {
                const field_name = (try self.expect(.identifier, "a field name")) orelse return null;
                try self.refuseWildcardName(field_name);
                // `circle(f64)` — a positional payload, which is a
                // tuple with a name in front of it (docs/RETURNS.md);
                // payload fields are named, always (D1).
                if (self.peekKind() != .colon) {
                    try self.report(
                        "luce.parse.expected",
                        field_name.span,
                        "a payload field is named, always: write {s}(name: {s})",
                        .{ self.text(name), self.text(field_name) },
                    );
                    return null;
                }
                _ = self.advance(); // the colon
                const field_type = (try self.typeName()) orelse return null;
                var default_value: ?*ast.Expression = null;
                var field_end = field_type.span.end;
                if (self.accept(.assign) != null) {
                    const written = (try self.expression()) orelse return null;
                    default_value = written;
                    field_end = written.span().end;
                }
                try fields.append(self.arena, .{
                    .name = self.text(field_name),
                    .name_span = field_name.span,
                    .type_name = field_type,
                    .default = default_value,
                    .span = .{ .start = field_name.span.start, .end = field_end },
                });
                previous_end = field_end;
                if (self.accept(.comma) == null) break;
            }
            if (try self.missingSeparator(previous_end)) return null;
            const closing = (try self.expectClose(.right_paren, opener)) orelse return null;
            written_end = closing.span.end;
        }
        try self.endOfStatement("end of line after the member");
        return .{
            .name = self.text(name),
            .name_span = name.span,
            .fields = try fields.toOwnedSlice(self.arena),
            .span = .{ .start = name.span.start, .end = written_end },
        };
    }

    // -- declarations: functions ------------------------------------------

    /// `static func` is a member-only declaration.  Visibility has
    /// already been dissolved by the surrounding struct/enum parser,
    /// so this function owns only the modifier and its ordering.
    fn staticFuncDecl(self: *Parser) Error!?ast.FuncDecl {
        const marker = self.advance(); // static
        if (self.peekKind() != .keyword_func) {
            if (self.peekKind() == .keyword_pub) {
                try self.report(
                    "luce.parse.static",
                    self.peek().span,
                    "visibility comes before static: write 'pub static func', not 'static pub func'",
                    .{},
                );
            } else if (self.peekKind() == .keyword_static) {
                try self.report(
                    "luce.parse.static",
                    self.peek().span,
                    "write static once, immediately before func",
                    .{},
                );
            } else {
                try self.report(
                    "luce.parse.static",
                    marker.span,
                    "static marks a member function: write 'static func name(...)'",
                    .{},
                );
            }
            return null;
        }
        var declaration = (try self.funcDecl()) orelse return null;
        declaration.is_static = true;
        declaration.span.start = marker.span.start;
        return declaration;
    }

    fn funcDecl(self: *Parser) Error!?ast.FuncDecl {
        const start = self.advance(); // func
        const name = (try self.expect(.identifier, "a function name")) orelse return null;
        try self.refuseWildcardName(name);
        const opener = (try self.expect(.left_paren, "'(' opening the parameter list")) orelse
            return null;
        const parameters = (try self.parameterList(opener, false)) orelse return null;

        // `-> T`, `-> T!`, `-> (A, B)`, `-> (A, B)!`, or a bare
        // `-> !`: the mark says the call may fail, the list says what
        // it hands back when it does not, and either may be absent
        // (docs/FAILURE.md, docs/RETURNS.md).
        var returns: std.ArrayList(ast.TypeName) = .empty;
        defer returns.deinit(self.arena);
        var fallible = false;
        var error_type: ?*ast.TypeName = null;
        if (self.accept(.arrow) != null) {
            if (self.peekKind() == .left_paren) {
                if (!try self.returnShape(&returns)) return null;
            } else if (self.peekKind() != .bang) {
                const only = (try self.typeName()) orelse return null;
                try returns.append(self.arena, only);
            }
            fallible = self.accept(.bang) != null;
            // `! E` (docs/ERRORS.md R2): the type the function fails
            // with.  Only after a `!`, and only when a type follows —
            // the block's `:` ends the signature either way.
            if (fallible and self.peekKind() == .identifier) {
                const failing = (try self.typeName()) orelse return null;
                const held = try self.arena.create(ast.TypeName);
                held.* = failing;
                error_type = held;
            }
        }
        const body = (try self.block("func")) orelse return null;
        return .{
            .name = self.text(name),
            .name_span = name.span,
            .parameters = parameters,
            .returns = try returns.toOwnedSlice(self.arena),
            .error_type = error_type,
            .fallible = fallible,
            .body = body,
            .span = .{ .start = start.span.start, .end = name.span.end },
        };
    }

    /// `extern func name(a: T, out b: U, ...) -> R`, with an optional
    /// `blocking` between the two keywords (docs/FFI.md).  No body —
    /// the shape is the whole declaration — no defaults, no
    /// fallibility mark, and at most one *declared* return: the C
    /// shape is the whole truth, and every refusal here says so.  The
    /// `out` slots widen what the call answers, not what C returns.
    fn externDecl(self: *Parser) Error!?ast.ExternDecl {
        const start = self.advance(); // extern
        var blocking = false;
        if (self.peekKind() == .identifier and std.mem.eql(u8, self.text(self.peek()), "blocking")) {
            _ = self.advance();
            blocking = true;
        }
        if ((try self.expect(.keyword_func, "func after extern")) == null) return null;
        const name = (try self.expect(.identifier, "a foreign function's name")) orelse return null;
        try self.refuseWildcardName(name);
        const opener = (try self.expect(.left_paren, "'(' opening the parameter list")) orelse
            return null;
        const parameters = (try self.parameterList(opener, true)) orelse return null;
        for (parameters) |parameter| {
            if (parameter.default != null) {
                try self.report(
                    "luce.parse.extern",
                    parameter.span,
                    "an extern parameter takes no default; the C shape is the whole truth",
                    .{},
                );
                return null;
            }
        }
        var returns: ?ast.TypeName = null;
        if (self.accept(.arrow) != null) {
            // A `(` is legal here — `(cfunc(...) -> R)?` closes the
            // function type before the `?` reaches its result — and a
            // written return *shape* is refused inside the
            // parenthesized-type rule, which knows a pair that travels
            // together is a struct.
            if (self.peekKind() == .bang) {
                try self.report(
                    "luce.parse.extern",
                    self.peek().span,
                    "an extern is not fallible; C reports failure in its return value, and the wrapper is where ! lives",
                    .{},
                );
                return null;
            }
            returns = (try self.typeName()) orelse return null;
            if (self.peekKind() == .bang) {
                try self.report(
                    "luce.parse.extern",
                    self.peek().span,
                    "an extern is not fallible; C reports failure in its return value, and the wrapper is where ! lives",
                    .{},
                );
                return null;
            }
        }
        if ((try self.expect(.newline, "end of line after an extern declaration")) == null) return null;
        return .{
            .name = self.text(name),
            .name_span = name.span,
            .parameters = parameters,
            .returns = returns,
            .blocking = blocking,
            .span = .{ .start = start.span.start, .end = name.span.end },
        };
    }

    /// Whether the cursor sits on `extern type` — the handle
    /// declaration rather than an extern function.  `type` is a
    /// contextual identifier, exactly as `blocking` is in
    /// `externDecl`: a keyword only in this position, so a program
    /// still owns the word everywhere else.
    fn atExternType(self: *const Parser) bool {
        if (self.peekKind() != .keyword_extern) return false;
        const next = self.tokenAhead(1);
        return next.kind == .identifier and std.mem.eql(u8, self.text(next), "type");
    }

    /// `extern type Name`, or `extern type Name = i32` — a nominal
    /// opaque handle at the C boundary (docs/FFI.md).  No body: the
    /// name is the whole declaration, and the optional `=` names the
    /// integer width an integer-shaped handle crosses at.  Only the
    /// four Tier-1 widths are representations; everything else is
    /// refused here, where the spelling is, rather than left for the
    /// resolver to call an unknown type.
    fn externTypeDecl(self: *Parser) Error!?ast.ExternTypeDecl {
        const start = self.advance(); // extern
        _ = self.advance(); // type — the caller has already looked
        const name = (try self.expect(.identifier, "a handle type's name")) orelse return null;
        try self.refuseWildcardName(name);
        var representation: ?ast.TypeName = null;
        if (self.accept(.assign) != null) {
            const written = (try self.typeName()) orelse return null;
            const spellings = [_][]const u8{ "u32", "i32", "u64", "i64" };
            var admitted = false;
            for (spellings) |spelling| {
                if (std.mem.eql(u8, written.name, spelling)) admitted = true;
            }
            if (!admitted or written.optional or written.arguments.len != 0 or written.wildcards != 0) {
                try self.report(
                    "luce.parse.extern",
                    written.span,
                    "an extern type representation must be `u32`, `i32`, `u64`, or `i64`",
                    .{},
                );
                return null;
            }
            representation = written;
        }
        if ((try self.expect(.newline, "end of line after an extern type declaration")) == null) return null;
        return .{
            .name = self.text(name),
            .name_span = name.span,
            .representation = representation,
            .span = .{ .start = start.span.start, .end = name.span.end },
        };
    }

    /// `extern struct Name:` — an ordinary value struct whose fields
    /// additionally have C's layout (docs/FFI.md).  The body grammar is
    /// a struct's own, shared whole: memberwise construction, field
    /// access, copies and zero values all come from the same machinery,
    /// and only the C-layout fact travels with the declaration.  What a
    /// field may hold at the boundary is stage 4's ruling.
    fn externStructDecl(self: *Parser) Error!?ast.StructDecl {
        const start = self.advance(); // extern — the caller has already looked
        var declaration = (try self.structDecl()) orelse return null;
        declaration.c_layout = true;
        declaration.span.start = start.span.start;
        return declaration;
    }

    /// `extern var name: T` — a C global's declared shape
    /// (docs/FFI.md).  No initializer — the C side owns the value —
    /// and no body: reads and writes are direct loads and stores of
    /// the symbol, with the bare semantics the Globals section states.
    fn externVarDecl(self: *Parser) Error!?ast.ExternVarDecl {
        const start = self.advance(); // extern
        _ = self.advance(); // var — the caller has already looked
        const name = (try self.expect(.identifier, "a C global's name")) orelse return null;
        try self.refuseWildcardName(name);
        if ((try self.expect(.colon, "':' before the global's type")) == null) return null;
        const written = (try self.typeName()) orelse return null;
        if (self.peekKind() == .assign) {
            try self.report(
                "luce.parse.extern",
                self.peek().span,
                "an extern var takes no initializer; the C side owns the value",
                .{},
            );
            return null;
        }
        if ((try self.expect(.newline, "end of line after an extern var declaration")) == null) return null;
        return .{
            .name = self.text(name),
            .name_span = name.span,
            .type_name = written,
            .span = .{ .start = start.span.start, .end = written.span.end },
        };
    }

    /// The one parameter grammar shared by functions and class
    /// initializers. The opener has already been consumed.
    fn parameterList(self: *Parser, opener: Token, admit_out: bool) Error!?[]ast.Parameter {
        var parameters: std.ArrayList(ast.Parameter) = .empty;
        defer parameters.deinit(self.arena);
        var previous_end = opener.span.end;
        while (!expr.endsList(self.peekKind(), .right_paren)) {
            // Every non-static member has an implied receiver. Refuse both
            // explicit receiver forms wherever they appear, including in a
            // top-level or static function.
            if (self.peekKind() == .keyword_self or
                (self.peekKind() == .keyword_var and self.peekAhead(1) == .keyword_self))
            {
                const receiver_start = self.peek();
                _ = self.accept(.keyword_var);
                const receiver = self.advance(); // self
                try self.report(
                    "luce.parse.self",
                    .{ .start = receiver_start.span.start, .end = receiver.span.end },
                    "self is implied; remove the parameter",
                    .{},
                );
                return null;
            }
            if (self.peekKind() == .keyword_var) {
                const marker = self.advance();
                try self.report(
                    "luce.parse.self",
                    marker.span,
                    "parameters are values and never var; use a local var or return the updated value",
                    .{},
                );
                return null;
            }
            // A marker on a parameter is the locals' mistake in a
            // parameter list (docs/VISIBILITY.md §5).
            if (self.peekKind() == .keyword_pub) {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "visibility applies to file-scope declarations and struct members",
                    .{},
                );
                return null;
            }
            // `out` is a contextual modifier in an extern parameter
            // list only, and only when another name follows — `out:
            // i32` stays a parameter *named* out, exactly as
            // `blocking` stays an ordinary identifier outside its
            // position (docs/FFI.md).
            var out = false;
            if (admit_out and self.peekKind() == .identifier and
                std.mem.eql(u8, self.text(self.peek()), "out") and
                self.peekAhead(1) == .identifier)
            {
                _ = self.advance();
                out = true;
            }
            const parameter_name = (try self.expect(.identifier, "a parameter name")) orelse
                return null;
            try self.refuseWildcardName(parameter_name);
            if ((try self.expect(.colon, "':' after the parameter name")) == null) return null;
            const parameter_type = (try self.typeName()) orelse return null;
            // `= EXPRESSION` — the parameter's default, one new
            // production in the one place a parameter is parsed
            // (docs/ARGS.md §1).  What the expression may *be* is
            // stage 4's question: the folder decides, so a bad default
            // is a constant's diagnostic and not a parse error.
            var default_value: ?*ast.Expression = null;
            var written_end = parameter_type.span.end;
            if (self.accept(.assign) != null) {
                const written = (try self.expression()) orelse return null;
                default_value = written;
                written_end = written.span().end;
            }
            try parameters.append(self.arena, .{
                .name = self.text(parameter_name),
                .name_span = parameter_name.span,
                .type_name = parameter_type,
                .default = default_value,
                .out = out,
                .span = .{ .start = parameter_name.span.start, .end = written_end },
            });
            previous_end = written_end;
            if (self.accept(.comma) == null) break;
        }
        if (try self.missingSeparator(previous_end)) return null;
        if ((try self.expectClose(.right_paren, opener)) == null) return null;
        return try parameters.toOwnedSlice(self.arena);
    }

    /// `-> (A, B)` — two or more types a function answers together.
    ///
    /// **There is no tuple.**  This is the one place the shape may be
    /// written, and every way of asking for it to be more than that
    /// gets its own sentence rather than falling into a generic one:
    /// an empty list, a list of one, a list that nests, and a list
    /// somebody tried to mark absent (docs/RETURNS.md).
    ///
    /// False after reporting.
    fn returnShape(self: *Parser, into: *std.ArrayList(ast.TypeName)) Error!bool {
        const opener = self.advance(); // (
        if (self.peekKind() == .right_paren) {
            const closing = self.advance();
            try self.report(
                "luce.parse.type",
                .{ .start = opener.span.start, .end = closing.span.end },
                "a function that answers nothing writes no arrow",
                .{},
            );
            return false;
        }
        var previous_end = opener.span.end;
        while (!expr.endsList(self.peekKind(), .right_paren)) {
            const element = (try self.typeName()) orelse return false;
            try into.append(self.arena, element);
            previous_end = element.span.end;
            if (self.accept(.comma) == null) break;
        }
        if (try self.missingSeparator(previous_end)) return false;
        const closing = (try self.expectClose(.right_paren, opener)) orelse return false;
        if (into.items.len == 1) {
            // Not a return shape at all: one type in parentheses is a
            // **parenthesized type**, which is that type, and the `?` a
            // reader came here for belongs to it — `-> (func() -> i64)?`
            // answers an optional function.  The arity is what tells
            // the two productions apart, and it is the only thing that
            // can: both open with `(` and the difference does not
            // appear until the comma does or does not (docs/BINDING.md
            // D7).  So `-> (i64)` is `-> i64`, exactly as `(i64)` is
            // `i64` anywhere else a type stands.
            var only = into.items[0];
            only.span = .{ .start = opener.span.start, .end = closing.span.end };
            if (!try self.refuseSecondQuestion(only)) return false;
            into.items[0] = (try self.optionalSuffix(only)) orelse return false;
            return true;
        }
        // `-> (i64, i64)?` — the `?` would be marking the *shape*, and
        // a shape is not a value that can be absent.  Each element may
        // carry one of its own, and `i64?` among them is ordinary.
        if (self.peekKind() == .question) {
            try self.report(
                "luce.parse.type",
                self.peek().span,
                "'?' marks a value that may be absent, and a return shape is not a value",
                .{},
            );
            return false;
        }
        return true;
    }

    // -- statements -------------------------------------------------------

    /// The `: NEWLINE INDENT …` body of a header.  `opener` names the
    /// keyword that opened it, so a missing or empty body can say which
    /// header is waiting for statements rather than which token the
    /// parser wanted.
    pub fn block(self: *Parser, opener: []const u8) Error!?ast.Block {
        if (!try self.colonOrLayout("':' to open the block")) return null;
        // A one-line body: ':' and a single statement on the same line.
        // Reached only when a colon was actually written — the
        // missing-colon recovery in `colonOrLayout` always leaves a
        // newline here, so it falls through to the indented path.  The
        // result is the same one-statement `Block` an indented body of
        // one line would build, so nothing downstream sees a
        // difference (docs/STATEMENTS.md, inline blocks).
        if (self.peekKind() != .newline) return try self.inlineBlock();
        if ((try self.expect(.newline, "end of line after ':'")) == null) return null;
        const opened = (try self.blockBody(opener)) orelse return null;

        var statements: std.ArrayList(ast.Statement) = .empty;
        defer statements.deinit(self.arena);
        while (self.peekKind() != .dedent and self.peekKind() != .end_of_file) {
            if (self.accept(.newline) != null) continue;
            if (self.peekKind() == .indent) {
                try self.unexpectedIndent();
                continue;
            }
            if (try self.statement()) |parsed| {
                try statements.append(self.arena, parsed);
            } else {
                self.recover();
            }
        }
        const closed = self.peek().span;
        _ = self.accept(.dedent);
        return .{
            .statements = try statements.toOwnedSlice(self.arena),
            .span = .{ .start = opened.span.start, .end = closed.end },
        };
    }

    /// A one-line block body: the single statement written after `:` on
    /// the same line.  The statement owns its own line ending — every
    /// simple statement consumes its trailing newline through
    /// `endOfStatement`, which is also what rejects a second statement
    /// with no separator (Luce has none) between them.  So this parses
    /// exactly one statement and stops, and a following `elif`, `else`,
    /// dedent, or sibling attaches exactly as after an indented body.
    fn inlineBlock(self: *Parser) Error!?ast.Block {
        const start = self.peek().span.start;
        const parsed = (try self.statement()) orelse return null;
        // One *simple* statement only.  A compound statement inline —
        // `if a: if b: run()` — nests two headers on one line, which is
        // the unreadable form the indented body exists to prevent; it
        // gets its own line (docs/STATEMENTS.md).
        switch (parsed) {
            .conditional, .while_loop, .for_range, .for_each, .match => {
                try self.report(
                    "luce.parse.expected",
                    .{ .start = start, .end = self.peek().span.start },
                    "an inline ':' body is one simple statement; put this block on its own indented lines",
                    .{},
                );
                return null;
            },
            else => {},
        }
        const statements = try self.arena.alloc(ast.Statement, 1);
        statements[0] = parsed;
        return .{ .statements = statements, .span = .{ .start = start, .end = self.peek().span.start } };
    }

    fn statement(self: *Parser) Error!?ast.Statement {
        if (!try self.enter("block")) return null;
        defer self.leave();

        // The construct a lexical mistake is measured against.  Nested
        // statements set and restore it, so an inner one that is
        // undamaged still reports even when the `if` around it was
        // where stage 2 spoke.
        const enclosing = self.statement_start;
        defer self.statement_start = enclosing;
        self.statement_start = self.peek().span.start;

        switch (self.peekKind()) {
            .keyword_let => return self.binding(false),
            .keyword_var => return self.binding(true),
            .keyword_weak => return self.weakBinding(),
            .keyword_const => {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "const declares at file scope; use let or var inside a function",
                    .{},
                );
                return null;
            },
            .keyword_if => return self.conditional(),
            .keyword_while => return self.whileLoop(),
            .keyword_for => return self.forLoop(),
            .keyword_match => return self.matchStatement(),
            .keyword_return => return self.returnStatement(),
            .keyword_break => {
                const item = self.advance();
                try self.endOfStatement("end of line after break");
                return .{ .break_statement = .{ .span = item.span } };
            },
            .keyword_continue => {
                const item = self.advance();
                try self.endOfStatement("end of line after continue");
                return .{ .continue_statement = .{ .span = item.span } };
            },
            .keyword_pass => {
                const item = self.advance();
                try self.endOfStatement("end of line after pass");
                return .{ .pass_statement = .{ .span = item.span } };
            },
            // Keywords that can only open something else: name the
            // mistake instead of failing as "expected an expression".
            .keyword_elif, .keyword_else => {
                const word = keywordWord(self.peekKind()).?;
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "'{s}' has no matching 'if' at this indentation",
                    .{word},
                );
                return null;
            },
            .keyword_static => {
                try self.report(
                    "luce.parse.static",
                    self.peek().span,
                    "static belongs before func inside a struct or enum, not inside a function body",
                    .{},
                );
                return null;
            },
            .keyword_func, .keyword_struct, .keyword_class, .keyword_interface, .keyword_alias, .keyword_enum, .keyword_union, .keyword_import => {
                const word = keywordWord(self.peekKind()).?;
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "'{s}' declarations belong at file scope, not inside a function",
                    .{word},
                );
                return null;
            },
            // A marker on a local is a category mistake, not a typo:
            // visibility is about the module boundary, and there is no
            // smaller boundary for it to mean anything at
            // (docs/VISIBILITY.md §5).  The statement behind it is
            // unmistakable, so it is read after the report — dropping
            // the binding too would turn one mistake into an unknown
            // name at every later use.
            .keyword_pub => {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "visibility applies to file-scope declarations and struct members",
                    .{},
                );
                _ = self.advance();
                return self.statement();
            },
            else => return self.assignOrExpression(),
        }
    }

    fn binding(self: *Parser, mutable: bool) Error!?ast.Statement {
        const start = self.advance(); // let or var
        return self.bindingAfter(start, mutable, false);
    }

    /// A weak slot is observable mutable state: the runtime writes `none`
    /// when the target's last strong reference dies. Keeping `var` explicit
    /// makes that fact visible in source and gives `weak let` one precise
    /// diagnostic.
    fn weakBinding(self: *Parser) Error!?ast.Statement {
        const start = self.advance(); // weak
        if (self.peekKind() == .keyword_let) {
            const immutable = self.advance();
            try self.report(
                "luce.parse.weak",
                .{ .start = start.span.start, .end = immutable.span.end },
                "weak storage changes to none when its target dies; write 'weak var', not 'weak let'",
                .{},
            );
            self.recover();
            return null;
        }
        if ((try self.expect(.keyword_var, "'var' after 'weak'")) == null) return null;
        return self.bindingAfter(start, true, true);
    }

    fn bindingAfter(self: *Parser, start: Token, mutable: bool, weak: bool) Error!?ast.Statement {
        const name = (try self.expect(.identifier, "a binding name")) orelse return null;
        try self.refuseWildcardName(name);
        // `let low, high = minmax(xs)` — a destructuring bind.  An
        // existing-name assignment uses its own statement path below.
        if (self.peekKind() == .comma) {
            if (weak) {
                try self.report(
                    "luce.parse.weak",
                    start.span,
                    "weak storage declares one explicitly typed place; declare each weak variable separately",
                    .{},
                );
                self.recover();
                return null;
            }
            return self.destructure(start, name, mutable);
        }
        var annotation: ?ast.TypeName = null;
        if (self.accept(.colon) != null) {
            annotation = (try self.typeName()) orelse return null;
            // `let low: i64, high: i64 = minmax(xs)`.  There is one
            // place a return shape is written and it is the signature;
            // the bind takes its types from the call
            // (docs/RETURNS.md).  An annotation on a *single* `let` is
            // untouched.
            if (self.peekKind() == .comma) {
                try self.report(
                    "luce.parse.type",
                    annotation.?.span,
                    "a destructuring bind takes its types from the call",
                    .{},
                );
                return null;
            }
        }
        // var name: Type — a late declaration; the slot starts at the
        // type's zero value (MEMORY.md).  let always initializes.
        if (mutable and annotation != null and self.peekKind() == .newline) {
            _ = self.advance();
            return .{ .variable = .{
                .name = self.text(name),
                .name_span = name.span,
                .annotation = annotation,
                .value = null,
                .weak = weak,
                .span = .{ .start = start.span.start, .end = annotation.?.span.end },
            } };
        }
        if (!mutable and annotation != null and self.peekKind() == .newline) {
            try self.report(
                "luce.parse.expected",
                self.peek().span,
                "let always initializes: write '= value', or use var for a late declaration",
                .{},
            );
            return null;
        }
        if ((try self.expect(.assign, "'=' with an initial value")) == null) return null;
        const value = (try self.expression()) orelse return null;
        // `let a = risky() catch:` — the block form of catch on a
        // binding.  The handler has no value to give the name, so it
        // is legal on one condition stage 4 owns: the block always
        // leaves (return, error, trap), and the name is only readable
        // on the path where the call succeeded (docs/FAILURE.md).
        if (self.peekKind() == .keyword_catch and expr.opensHandler(self)) {
            const attempt: ast.Statement = if (mutable) .{ .variable = .{
                .name = self.text(name),
                .name_span = name.span,
                .annotation = annotation,
                .value = value,
                .weak = weak,
                .span = .{ .start = start.span.start, .end = value.span().end },
            } } else .{ .let = .{
                .name = self.text(name),
                .name_span = name.span,
                .annotation = annotation,
                .value = value,
                .span = .{ .start = start.span.start, .end = value.span().end },
            } };
            return self.guarded(attempt);
        }
        // A block closure consumed its own newline, indentation, and closing
        // dedent. The next token is already the next statement at this level.
        if (!endsWithBlock(value)) try self.endOfStatement("end of line after the binding");
        const span: Span = .{ .start = start.span.start, .end = value.span().end };
        if (mutable) {
            return .{ .variable = .{
                .name = self.text(name),
                .name_span = name.span,
                .annotation = annotation,
                .value = value,
                .weak = weak,
                .span = span,
            } };
        }
        return .{ .let = .{
            .name = self.text(name),
            .name_span = name.span,
            .annotation = annotation,
            .value = value,
            .span = span,
        } };
    }

    /// `let a, b = f()` / `var a, b = f()`, from the comma on.
    ///
    /// **One keyword governs the whole bind.**  Zig lets each element
    /// carry its own `const` or `var` and buys exactness at one token;
    /// it loses here because every binding statement in Luce begins
    /// with the keyword that governs it and the statement dispatch
    /// reads that keyword at position zero.  Refusing first is
    /// reversible — `let a, var b = f()` is a strict superset, so if
    /// the corpus asks for it nothing written before then changes
    /// meaning (docs/RETURNS.md).
    fn destructure(
        self: *Parser,
        start: Token,
        first: Token,
        mutable: bool,
    ) Error!?ast.Statement {
        var names: std.ArrayList(ast.Name) = .empty;
        defer names.deinit(self.arena);
        try names.append(self.arena, .{ .text = self.text(first), .span = first.span });
        while (self.accept(.comma) != null) {
            if (self.peekKind() == .keyword_let or self.peekKind() == .keyword_var) {
                try self.report(
                    "luce.parse.assign",
                    self.peek().span,
                    "one let or one var governs the whole bind",
                    .{},
                );
                return null;
            }
            const next = (try self.expect(.identifier, "a binding name")) orelse return null;
            try self.refuseWildcardName(next);
            if (self.peekKind() == .colon) {
                try self.report(
                    "luce.parse.type",
                    self.peek().span,
                    "a destructuring bind takes its types from the call",
                    .{},
                );
                return null;
            }
            try names.append(self.arena, .{ .text = self.text(next), .span = next.span });
        }
        if ((try self.expect(.assign, "'=' with the call the names come from")) == null) return null;
        const value = (try self.expression()) orelse return null;
        // `let a, b = f() catch 0, 0`.  A fallback for two values is a
        // comma list standing to the right of an operator, which has no
        // reading that does not first invent a tuple expression and
        // then give it a precedence — so the comma is where the rule is
        // met (docs/RETURNS.md).
        if (self.peekKind() == .comma) {
            try self.report(
                "luce.parse.assign",
                self.peek().span,
                "a destructuring bind takes one call on the right, and catch can supply only one value: write try, or handle it as a statement",
                .{},
            );
            return null;
        }
        try self.endOfStatement("end of line after the binding");
        return .{ .destructure = .{
            .names = try names.toOwnedSlice(self.arena),
            .mutable = mutable,
            .value = value,
            .span = .{ .start = start.span.start, .end = value.span().end },
        } };
    }

    fn conditional(self: *Parser) Error!?ast.Statement {
        // Held across the elif recursion below as well as the block,
        // so neither a tower of `if`s nor a long elif chain can
        // outrun the native stack.
        if (!try self.enter("block")) return null;
        defer self.leave();

        const start = self.advance(); // if or elif
        const written = (try self.expression()) orelse return null;
        const condition = (try self.conditionAfterAssign(written)) orelse return null;
        const then_block = (try self.block(if (start.kind == .keyword_elif) "elif" else "if")) orelse return null;

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
        } else if (self.accept(.keyword_else)) |keyword| {
            // `else if` is how C, Rust and JavaScript spell what Luce
            // spells `elif`.  Without this the reader is told the
            // block wanted a ':' and found the keyword 'if', which
            // describes the parser rather than the mistake.
            if (self.peekKind() == .keyword_if) {
                const found_token = self.advance();
                try self.report(
                    "luce.parse.expected",
                    .{ .start = keyword.span.start, .end = found_token.span.end },
                    "write 'elif': Luce chains conditions with one keyword, not 'else if'",
                    .{},
                );
                return null;
            }
            else_block = (try self.block("else")) orelse return null;
        }
        return .{ .conditional = .{
            .condition = condition,
            .then_block = then_block,
            .else_block = else_block,
            .span = .{ .start = start.span.start, .end = condition.span().end },
        } };
    }

    /// `if x = 1:` — the C and Python habit.  `=` is a statement in
    /// Luce, so the condition just stops early and the block reports a
    /// missing ':'.  Catch it at the operator, where the fix is, and
    /// then read on as the comparison that was plainly meant, so the
    /// body is still parsed and its own mistakes still reported.  One
    /// habit, one diagnostic, and nothing downstream of it is lost.
    fn conditionAfterAssign(self: *Parser, condition: *ast.Expression) Error!?*ast.Expression {
        if (self.peekKind() != .assign) return condition;
        const operator = self.advance();
        try self.report(
            "luce.parse.expected",
            operator.span,
            "'=' assigns a value; write '==' to compare",
            .{},
        );
        const right = (try self.expression()) orelse return null;
        return self.make(.{ .binary = .{
            .op = .equal,
            .left = condition,
            .right = right,
            .span = .{ .start = condition.span().start, .end = right.span().end },
        } });
    }

    fn whileLoop(self: *Parser) Error!?ast.Statement {
        const start = self.advance();
        const written = (try self.expression()) orelse return null;
        const condition = (try self.conditionAfterAssign(written)) orelse return null;
        const body = (try self.block("while")) orelse return null;
        return .{ .while_loop = .{
            .condition = condition,
            .body = body,
            .span = .{ .start = start.span.start, .end = condition.span().end },
        } };
    }

    fn forLoop(self: *Parser) Error!?ast.Statement {
        const start = self.advance();
        const name = (try self.expect(.identifier, "a loop variable")) orelse return null;
        try self.refuseWildcardName(name);
        // for key, value in ...: — an optional second binding.  A
        // two-name loop is never a range, so this precedes that check.
        var value_name: ?[]const u8 = null;
        var value_token: ?Token = null;
        if (self.accept(.comma) != null) {
            const second = (try self.expect(.identifier, "a second loop variable")) orelse return null;
            try self.refuseWildcardName(second);
            value_name = self.text(second);
            value_token = second;
        }
        if ((try self.expect(.keyword_in, "'in' between the loop variable and what it walks")) == null)
            return null;

        // for i in range(a, b): keeps its dedicated integer lowering.
        if (value_name == null and self.peekKind() == .identifier and
            std.mem.eql(u8, self.text(self.peek()), "range") and
            self.peekAhead(1) == .left_paren)
        {
            _ = self.advance(); // range
            const opener = self.advance(); // (
            const first = (try self.expression()) orelse return null;
            if ((try self.expect(.comma, "',' between the range bounds")) == null) return null;
            const second = (try self.expression()) orelse return null;
            _ = self.accept(.comma); // a trailing comma is fine
            if (self.peekKind() != .right_paren) {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "range takes exactly two bounds: range(start, end)",
                    .{},
                );
                return null;
            }
            if ((try self.expectClose(.right_paren, opener)) == null) return null;
            const body = (try self.block("for")) orelse return null;
            return .{ .for_range = .{
                .name = self.text(name),
                .start = first,
                .end = second,
                .body = body,
                .span = .{ .start = start.span.start, .end = name.span.end },
            } };
        }

        const iterable = (try self.expression()) orelse return null;
        const body = (try self.block("for")) orelse return null;
        const end = if (value_token) |token| token.span.end else name.span.end;
        return .{ .for_each = .{
            .name = self.text(name),
            .value_name = value_name,
            .iterable = iterable,
            .body = body,
            .span = .{ .start = start.span.start, .end = end },
        } };
    }

    /// `match m:` — an indented arm per member, each a bare name and
    /// the block it opens, with an optional `else:` last
    /// (docs/ENUMS.md R1, R3).
    ///
    /// Which names are *legal* arms is stage 4's question: the parser
    /// does not know the scrutinee's type, and a name that spells no
    /// member is a diagnostic about an enum rather than about syntax.
    /// What it does know is the two shapes a reader arrives with from
    /// another language — `case stored:` and `Method.stored:` — and
    /// both get the one sentence that says how Luce writes it.
    fn matchStatement(self: *Parser) Error!?ast.Statement {
        if (!try self.enter("block")) return null;
        defer self.leave();

        const start = self.advance(); // match
        const scrutinee = (try self.expression()) orelse return null;
        if (!try self.colonOrLayout("':' after what is matched")) return null;
        if ((try self.expect(.newline, "end of line after ':'")) == null) return null;
        if ((try self.blockBody("match")) == null) return null;

        var arms: std.ArrayList(ast.MatchArm) = .empty;
        defer arms.deinit(self.arena);
        var else_block: ?ast.Block = null;
        var else_span: ?Span = null;
        while (self.peekKind() != .dedent and self.peekKind() != .end_of_file) {
            if (self.accept(.newline) != null) continue;
            if (self.peekKind() == .indent) {
                try self.unexpectedIndent();
                continue;
            }
            // The catch-all arm is `else` or the wildcard `_` — the same
            // arm for everything the others did not name (docs/UNION.md).
            const is_underscore = self.peekKind() == .identifier and
                std.mem.eql(u8, self.text(self.peek()), "_");
            if (self.peekKind() == .keyword_else or is_underscore) {
                const keyword = self.advance();
                if (else_span != null) {
                    try self.report(
                        "luce.parse.expected",
                        keyword.span,
                        "one catch-all per match: else or _ is the arm for everything the others did not name",
                        .{},
                    );
                    self.recover();
                    continue;
                }
                else_span = keyword.span;
                else_block = (try self.block(if (is_underscore) "_" else "else")) orelse {
                    self.recover();
                    continue;
                };
                continue;
            }
            if (else_span != null) {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "else catches everything the arms above it did not, so it comes last",
                    .{},
                );
                self.recover();
                continue;
            }
            if (try self.matchArm()) |arm| {
                try arms.append(self.arena, arm);
            } else {
                self.recover();
            }
        }
        _ = self.accept(.dedent);
        return .{ .match = .{
            .scrutinee = scrutinee,
            .arms = try arms.toOwnedSlice(self.arena),
            .else_block = else_block,
            .else_span = else_span,
            .span = .{ .start = start.span.start, .end = scrutinee.span().end },
        } };
    }

    /// `match expr: pattern => value; _ => value` — a match written
    /// where an expression is expected (docs/ENUMS.md).  Same block
    /// shape as the statement form, but every arm yields with `=>`,
    /// and stage 4 desugars the whole thing to a hidden slot the arms
    /// fill and the surrounding expression reads.  Called from the
    /// expression grammar; the value it answers is one `*Expression`.
    pub fn matchValueExpression(self: *Parser) Error!?*ast.Expression {
        if (!try self.enter("block")) return null;
        defer self.leave();

        const start = self.advance(); // match
        const scrutinee = (try self.expression()) orelse return null;
        if (!try self.colonOrLayout("':' after what is matched")) return null;
        if ((try self.expect(.newline, "end of line after ':'")) == null) return null;
        if ((try self.blockBody("match")) == null) return null;

        var arms: std.ArrayList(ast.MatchValueArm) = .empty;
        defer arms.deinit(self.arena);
        var else_value: ?*ast.Expression = null;
        var else_span: ?Span = null;
        var end = scrutinee.span().end;
        while (self.peekKind() != .dedent and self.peekKind() != .end_of_file) {
            if (self.accept(.newline) != null) continue;
            if (self.peekKind() == .indent) {
                try self.unexpectedIndent();
                continue;
            }
            // The catch-all arm is `else` or the wildcard `_` — the
            // same arm for everything the others did not name.
            const is_underscore = self.peekKind() == .identifier and
                std.mem.eql(u8, self.text(self.peek()), "_");
            if (self.peekKind() == .keyword_else or is_underscore) {
                const keyword = self.advance();
                if (else_span != null) {
                    try self.report(
                        "luce.parse.expected",
                        keyword.span,
                        "one catch-all per match: else or _ is the arm for everything the others did not name",
                        .{},
                    );
                    self.recover();
                    continue;
                }
                else_span = keyword.span;
                if ((try self.expect(.fat_arrow, "'=>' before the value this arm yields")) == null) {
                    self.recover();
                    continue;
                }
                const value = (try self.expression()) orelse {
                    self.recover();
                    continue;
                };
                else_value = value;
                end = value.span().end;
                continue;
            }
            if (else_span != null) {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "else catches everything the arms above it did not, so it comes last",
                    .{},
                );
                self.recover();
                continue;
            }
            if (try self.expressionArm()) |arm| {
                end = arm.value.span().end;
                try arms.append(self.arena, arm);
            } else {
                self.recover();
            }
        }
        _ = self.accept(.dedent);
        return try expr.make(self, .{ .match_value = .{
            .scrutinee = scrutinee,
            .arms = try arms.toOwnedSlice(self.arena),
            .else_value = else_value,
            .else_span = else_span,
            .span = .{ .start = start.span.start, .end = end },
        } });
    }

    /// The arm's header — everything up to the `:` suite or `=>`
    /// value: a member name and optional payload bindings, or literal
    /// `values`.  `label` names the arm for the suite's own
    /// diagnostics.  Shared by the statement arm and the
    /// expression-valued arm, which differ only in what follows.
    const ArmHeader = struct {
        name: []const u8 = "",
        name_span: Span,
        bindings: []ast.Name = &.{},
        values: []ast.ValuePattern = &.{},
        label: []const u8,
        span: Span,
    };

    /// One arm's header: a member name, an optional parenthesized
    /// field-name list — the union payload extension (docs/UNION.md
    /// D5), names only, no types — or the literal patterns of a value
    /// arm.  The `:` suite or `=>` value is the caller's to read.
    fn matchArmHeader(self: *Parser) Error!?ArmHeader {
        // A literal opens a value arm; a name opens a member arm.
        // The two vocabularies never collide, because a member is
        // always a bare identifier.
        switch (self.peekKind()) {
            .int_literal,
            .float_literal,
            .char_literal,
            .string_literal,
            .keyword_true,
            .keyword_false,
            .minus,
            => return self.valuePatternHeader(),
            // `zero..nine:` and `comma, colon:` — a name followed by a
            // range or a comma can only be a value arm, because a
            // member arm is one bare name.  A lone `limit:` stays a
            // member arm here; stage 4 reads it as a constant when the
            // scrutinee is a value.
            .identifier => if (self.peekAhead(1) == .dot_dot or self.peekAhead(1) == .comma)
                return self.valuePatternHeader(),
            else => {},
        }
        // `case stored:` — Python's second keyword, carrying nothing
        // the colon does not (docs/ENUMS.md Q3).
        if (self.peekKind() == .identifier and
            std.mem.eql(u8, self.text(self.peek()), "case") and
            self.peekAhead(1) == .identifier)
        {
            const keyword = self.advance();
            try self.report(
                "luce.parse.expected",
                .{ .start = keyword.span.start, .end = self.peek().span.end },
                "a match arm is a bare member name: write '{s}:'",
                .{self.text(self.peek())},
            );
            return null;
        }
        const name = (try self.expect(.identifier, "a member name opening an arm")) orelse return null;
        try self.refuseWildcardName(name);
        // `Method.stored:` — qualified, which says every line what the
        // scrutinee already said once (R3).
        if (self.peekKind() == .dot and self.peekAhead(1) == .identifier) {
            _ = self.advance();
            const member = self.advance();
            try self.report(
                "luce.parse.expected",
                .{ .start = name.span.start, .end = member.span.end },
                "a match arm is a bare member name: write '{s}:', not '{s}.{s}:'",
                .{ self.text(member), self.text(name), self.text(member) },
            );
            return null;
        }
        var bindings: std.ArrayList(ast.Name) = .empty;
        defer bindings.deinit(self.arena);
        var written_end = name.span.end;
        if (self.peekKind() == .left_paren) {
            const opener = self.advance();
            if (self.peekKind() == .right_paren) {
                try self.report(
                    "luce.parse.expected",
                    .{ .start = opener.span.start, .end = self.peek().span.end },
                    "parentheses bind payload fields: name at least one, or write '{s}:' bare",
                    .{self.text(name)},
                );
                return null;
            }
            var previous_end = opener.span.end;
            while (!expr.endsList(self.peekKind(), .right_paren)) {
                const bound = (try self.expect(.identifier, "a field name to bind")) orelse return null;
                try self.refuseWildcardName(bound);
                // `circle(radius: f64)` — the declaration's field
                // list where the arm's binding list belongs.  An arm
                // binds by name alone; the types were declared once.
                if (self.peekKind() == .colon) {
                    try self.report(
                        "luce.parse.expected",
                        self.peek().span,
                        "an arm binds fields by name alone: write {s}({s})",
                        .{ self.text(name), self.text(bound) },
                    );
                    return null;
                }
                try bindings.append(self.arena, .{ .text = self.text(bound), .span = bound.span });
                previous_end = bound.span.end;
                if (self.accept(.comma) == null) break;
            }
            if (try self.missingSeparator(previous_end)) return null;
            const closing = (try self.expectClose(.right_paren, opener)) orelse return null;
            written_end = closing.span.end;
        }
        return .{
            .name = self.text(name),
            .name_span = name.span,
            .bindings = try bindings.toOwnedSlice(self.arena),
            .label = self.text(name),
            .span = .{ .start = name.span.start, .end = written_end },
        };
    }

    /// A value arm's header: literal patterns separated by commas,
    /// each a literal or `low .. high` — an inclusive range.  The
    /// parser reads expressions and stage 4 requires literals, so a
    /// non-literal is refused with what it found rather than with a
    /// parse error.
    fn valuePatternHeader(self: *Parser) Error!?ArmHeader {
        var patterns: std.ArrayList(ast.ValuePattern) = .empty;
        defer patterns.deinit(self.arena);
        const start = self.peek().span.start;
        var written_end = start;
        while (true) {
            const low = (try self.expression()) orelse return null;
            var high: ?*ast.Expression = null;
            written_end = low.span().end;
            if (self.accept(.dot_dot) != null) {
                const top = (try self.expression()) orelse return null;
                high = top;
                written_end = top.span().end;
            }
            try patterns.append(self.arena, .{
                .low = low,
                .high = high,
                .span = .{ .start = low.span().start, .end = written_end },
            });
            if (self.accept(.comma) == null) break;
        }
        return .{
            .name = "",
            .name_span = .{ .start = start, .end = written_end },
            .values = try patterns.toOwnedSlice(self.arena),
            .label = "match arm",
            .span = .{ .start = start, .end = written_end },
        };
    }

    /// One statement arm: a header, then the block its colon opens.
    fn matchArm(self: *Parser) Error!?ast.MatchArm {
        const header = (try self.matchArmHeader()) orelse return null;
        const body = (try self.block(header.label)) orelse return null;
        return .{
            .name = header.name,
            .name_span = header.name_span,
            .bindings = header.bindings,
            .values = header.values,
            .body = body,
            .span = header.span,
        };
    }

    /// One expression-valued arm: a header, then `=>` and the value
    /// it yields.
    fn expressionArm(self: *Parser) Error!?ast.MatchValueArm {
        const header = (try self.matchArmHeader()) orelse return null;
        if ((try self.expect(.fat_arrow, "'=>' before the value this arm yields")) == null) return null;
        const value = (try self.expression()) orelse return null;
        return .{
            .name = header.name,
            .name_span = header.name_span,
            .bindings = header.bindings,
            .values = header.values,
            .value = value,
            .span = header.span,
        };
    }

    fn returnStatement(self: *Parser) Error!?ast.Statement {
        const start = self.advance();
        if (self.accept(.newline) != null) {
            return .{ .return_statement = .{ .values = &.{}, .span = start.span } };
        }
        var values: std.ArrayList(*ast.Expression) = .empty;
        defer values.deinit(self.arena);
        const value = (try self.expression()) orelse return null;
        try values.append(self.arena, value);
        // `return a, b` — one expression per value the signature
        // declared, and stage 4 is what compares the two counts
        // (docs/RETURNS.md).
        var last = value;
        while (self.accept(.comma) != null) {
            last = (try self.expression()) orelse return null;
            try values.append(self.arena, last);
        }
        if (!endsWithBlock(last)) try self.endOfStatement("end of line after return");
        return .{ .return_statement = .{
            .values = try values.toOwnedSlice(self.arena),
            .span = .{ .start = start.span.start, .end = last.span().end },
        } };
    }

    // -- assignment and its targets ---------------------------------------

    // PLACE = expression, or a bare expression statement.  The place
    // is parsed as an ordinary expression and then classified: a name,
    // one dotted field on a name, or an indexed expression.
    fn assignOrExpression(self: *Parser) Error!?ast.Statement {
        const left = (try self.expression()) orelse return null;
        // `low, high = minmax(xs)` — the later SELF polish ruling
        // reopened RETURNS.md's provisional refusal for state that
        // travels through existing bindings.  It is its own narrow
        // statement: bare names only, and no compound form.
        if (self.peekKind() == .comma) return self.assignMany(left);
        // `call catch:` — the handler form, for a recovery that is more
        // than one expression.  The Pratt loop declined the `catch` on
        // seeing the colon behind it, so it is still here.
        if (self.peekKind() == .keyword_catch) {
            return self.guarded(.{ .expression = .{ .value = left, .span = left.span() } });
        }
        const compound = compoundOp(self.peekKind());
        if (self.peekKind() != .assign and compound == null) {
            // `x in xs` outside a for header: `in` is not an operator,
            // so say that rather than "expected end of line".
            if (self.peekKind() == .keyword_in) {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "'in' is part of a for header; there is no 'in' operator",
                    .{},
                );
                return null;
            }
            // `print "hi"` — a call written without its parentheses,
            // the reflex every Python 2 and shell traveller arrives
            // with.  A bare name followed by the start of another
            // expression, on the same line, is never anything else.
            if (left.* == .name and expr.startsExpression(self.peekKind()) and
                self.sameLine(left.span().end, self.peek().span.start))
            {
                // The same shape catches a keyword from another
                // language standing where a statement belongs
                // (`elseif cond:`), and that word is the better
                // answer than "you forgot the parentheses".
                if (foreignWord(left.name.text)) |advice| {
                    try self.report("luce.parse.expected", left.span(), "{s}", .{advice});
                    return null;
                }
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "a call needs its parentheses: write '{s}(...)'",
                    .{left.name.text},
                );
                return null;
            }
            if (try self.handlerOnOneLine(left)) return null;
            if (!endsWithBlock(left)) try self.endOfStatement("end of line after the expression");
            return .{ .expression = .{ .value = left, .span = left.span() } };
        }
        _ = self.advance(); // '=' or 'OP='

        const target = (try self.targetFrom(left)) orelse return null;
        const value = (try self.expression()) orelse return null;
        const assigned: ast.Statement = .{ .assign = .{
            .target = target,
            .compound = compound,
            .value = value,
            .span = .{ .start = target.span().start, .end = value.span().end },
        } };
        // `place = call() catch:` — the same handler form.  Only a
        // plain assignment takes it: a compound one reads its place
        // first, so there would be two things happening in front of
        // the word `catch` and only one of them can fail.
        if (self.peekKind() == .keyword_catch) {
            if (compound != null) {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "catch guards a plain assignment; write the call on its own line",
                    .{},
                );
                return null;
            }
            return self.guarded(assigned);
        }
        if (try self.handlerOnOneLine(value)) return null;
        if (!endsWithBlock(value)) try self.endOfStatement("end of line after the assignment");
        return assigned;
    }

    /// `a, b = f()` from the first comma onward.  Every target is a
    /// bare existing name; stage 4 decides whether each one is a
    /// mutable binding and whether the returned value fits it.
    fn assignMany(self: *Parser, first: *ast.Expression) Error!?ast.Statement {
        var names: std.ArrayList(ast.Name) = .empty;
        defer names.deinit(self.arena);

        const first_name = switch (first.*) {
            .name => |name| name,
            else => {
                try self.report(
                    "luce.parse.assign",
                    first.span(),
                    "multi-return assignment targets bare var names, not fields or indexes",
                    .{},
                );
                return null;
            },
        };
        if (std.mem.eql(u8, first_name.text, "_")) {
            try self.report(
                "luce.parse.assign",
                first_name.span,
                "_ is the array-shape wildcard, not an assignment target",
                .{},
            );
            return null;
        }
        try names.append(self.arena, .{ .text = first_name.text, .span = first_name.span });

        while (self.accept(.comma) != null) {
            const written = (try self.expression()) orelse return null;
            const name = switch (written.*) {
                .name => |name| name,
                else => {
                    try self.report(
                        "luce.parse.assign",
                        written.span(),
                        "multi-return assignment targets bare var names, not fields or indexes",
                        .{},
                    );
                    return null;
                },
            };
            if (std.mem.eql(u8, name.text, "_")) {
                try self.report(
                    "luce.parse.assign",
                    name.span,
                    "_ is the array-shape wildcard, not an assignment target",
                    .{},
                );
                return null;
            }
            try names.append(self.arena, .{ .text = name.text, .span = name.span });
        }

        if (compoundOp(self.peekKind()) != null) {
            try self.report(
                "luce.parse.assign",
                self.peek().span,
                "multi-return assignment has no compound form; use one '=' with the call whose values replace the names",
                .{},
            );
            return null;
        }
        if ((try self.expect(.assign, "'=' after the assignment targets")) == null) return null;
        const value = (try self.expression()) orelse return null;
        if (self.peekKind() == .comma) {
            try self.report(
                "luce.parse.assign",
                self.peek().span,
                "multi-return assignment takes one call on the right; there are no tuple or comma-list expressions",
                .{},
            );
            return null;
        }
        const assigned: ast.Statement = .{ .assign_many = .{
            .names = try names.toOwnedSlice(self.arena),
            .value = value,
            .span = .{ .start = first.span().start, .end = value.span().end },
        } };
        if (self.peekKind() == .keyword_catch) return self.guarded(assigned);
        if (try self.handlerOnOneLine(value)) return null;
        try self.endOfStatement("end of line after the assignment");
        return assigned;
    }

    /// `f() catch reason: print(reason)` — the binding handler with its
    /// body on the same line.
    ///
    /// `opensHandler` needs the newline to tell `catch NAME:` from a
    /// slice whose start ends in a fallback name, so without one the
    /// Pratt loop read the whole thing as the operator form and left a
    /// colon behind.  "Expected end of line, found ':'" is true and
    /// useless: the reader wrote a handler, and what they need to know
    /// is that its body goes on the next line.  Only a `catch` whose
    /// fallback is a bare name can arrive here, which is exactly the
    /// shape that was meant.
    fn handlerOnOneLine(self: *Parser, value: *ast.Expression) Error!bool {
        if (self.peekKind() != .colon) return false;
        if (value.* != .binary or value.binary.op != .catch_error) return false;
        if (value.binary.right.* != .name) return false;
        try self.report(
            "luce.parse.expected",
            self.peek().span,
            "a catch handler is a block: put its body on the next line, indented under '{s}:'",
            .{value.binary.right.name.text},
        );
        return true;
    }

    /// The `catch:` handler behind a statement whose call may raise,
    /// and the optional name `catch reason:` binds the error's words
    /// to for the length of the block (docs/FAILURE.md).
    fn guarded(self: *Parser, attempt: ast.Statement) Error!?ast.Statement {
        const keyword = self.advance(); // catch
        var reason: ?ast.Name = null;
        if (self.peekKind() == .identifier) {
            const name = self.advance();
            try self.refuseWildcardName(name);
            reason = .{ .text = self.text(name), .span = name.span };
        }
        const handler = (try self.block("catch")) orelse return null;
        const held = try self.arena.create(ast.Statement);
        held.* = attempt;
        return .{ .guarded = .{
            .attempt = held,
            .binding = reason,
            .handler = handler,
            .span = .{ .start = attempt.span().start, .end = keyword.span.end },
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
            .slash_slash_assign => .floor_divide,
            .percent_assign => .modulo,
            .ampersand_assign => .bit_and,
            .pipe_assign => .bit_or,
            .caret_assign => .bit_xor,
            .shift_left_assign => .shift_left,
            .shift_right_assign => .shift_right,
            else => null,
        };
    }

    fn targetFrom(self: *Parser, left: *ast.Expression) Error!?ast.Target {
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
            .slice_range => {
                try self.report(
                    "luce.parse.assign",
                    left.span(),
                    "a slice copies; assign to one element, or rebuild the whole value",
                    .{},
                );
                return null;
            },
            else => {
                try self.report(
                    "luce.parse.assign",
                    left.span(),
                    "cannot assign to this expression",
                    .{},
                );
                return null;
            },
        }
    }

    // -- the bridge to the expression grammar -----------------------------

    fn expression(self: *Parser) Error!?*ast.Expression {
        return expr.expression(self);
    }

    fn make(self: *Parser, value: ast.Expression) Error!*ast.Expression {
        return expr.make(self, value);
    }
};

/// What a word that is a keyword in some *other* language should be
/// written as here, or null when the word is not one of those habits.
///
/// Only consulted where a bare name is already known to be a mistake —
/// at file scope, and at the head of a statement that runs straight
/// into another expression.  In both places a hit is the reader's
/// other language speaking, not a variable they meant to use, so the
/// table can be generous without ever firing on a valid program.
// ---------------------------------------------------------------------------
// Naming a token for a person, and guessing at a wrong one
// ---------------------------------------------------------------------------

fn foreignWord(word: []const u8) ?[]const u8 {
    const import_advice = "imports name one module: 'import name' for a file beside " ++
        "this one, 'import " ++ source_mod.standard_namespace ++ ".name' for the standard library";
    const habits = [_]struct { word: []const u8, advice: []const u8 }{
        .{ .word = "elseif", .advice = "write 'elif': Luce chains conditions with one keyword" },
        .{ .word = "elsif", .advice = "write 'elif': Luce chains conditions with one keyword" },
        .{ .word = "foreach", .advice = "loops are written 'for x in xs:'" },
        .{ .word = "switch", .advice = "there is no switch; write 'match' over an enum, or chain 'if' and 'elif'" },
        .{ .word = "case", .advice = "a match arm is a bare member name: write 'stored:', not 'case stored:'" },
        .{ .word = "def", .advice = "functions are declared with 'func'" },
        .{ .word = "fn", .advice = "functions are declared with 'func'" },
        .{ .word = "fun", .advice = "functions are declared with 'func'" },
        .{ .word = "function", .advice = "functions are declared with 'func'" },
        .{ .word = "type", .advice = "type aliases are declared with 'alias': write 'alias Name = Type'" },
        .{ .word = "final", .advice = "file-scope constants are declared with 'const'" },
        .{ .word = "include", .advice = import_advice },
        .{ .word = "require", .advice = import_advice },
        .{ .word = "use", .advice = import_advice },
        .{ .word = "pub", .advice = "write 'public' in full" },
    };
    for (habits) |habit| {
        if (std.mem.eql(u8, habit.word, word)) return habit.advice;
    }
    return null;
}

/// The keyword `word` is a mis-cased spelling of, or null.  `Func`,
/// `STRUCT` and `If` are the same mistake as `def`, answered from the
/// lexer's own table rather than a second list of words.
fn miscasedKeyword(word: []const u8) ?[]const u8 {
    for (lex_mod.keywords) |keyword| {
        if (std.mem.eql(u8, keyword.word, word)) return null;
        if (std.ascii.eqlIgnoreCase(keyword.word, word)) return keyword.word;
    }
    return null;
}

/// The source word behind a keyword token, or null when the kind is
/// not a keyword.  Reads the lexer's own table, so the two can never
/// disagree.
pub fn keywordWord(kind: Kind) ?[]const u8 {
    for (lex_mod.keywords) |keyword| {
        if (keyword.kind == kind) return keyword.word;
    }
    return null;
}

/// A fixed English name for every token kind, for "expected X, found
/// Y" messages.  Exhaustive on purpose — a new token kind is a
/// compile error here, not a silent "unexpected token".
pub fn describe(kind: Kind) []const u8 {
    return switch (kind) {
        .newline => "end of line",
        .indent => "an indented block",
        .dedent => "the end of a block",
        .end_of_file => "end of file",

        .identifier => "a name",
        .keyword_func => "the keyword 'func'",
        .keyword_extern => "the keyword 'extern'",
        .keyword_static => "the keyword 'static'",
        .keyword_struct => "the keyword 'struct'",
        .keyword_class => "the keyword 'class'",
        .keyword_init => "the keyword 'init'",
        .keyword_deinit => "the keyword 'deinit'",
        .keyword_interface => "the keyword 'interface'",
        .keyword_mutating => "the keyword 'mutating'",
        .keyword_alias => "the keyword 'alias'",
        .keyword_enum => "the keyword 'enum'",
        .keyword_union => "the keyword 'union'",
        .keyword_match => "the keyword 'match'",
        .keyword_const => "the keyword 'const'",
        .keyword_let => "the keyword 'let'",
        .keyword_var => "the keyword 'var'",
        .keyword_weak => "the keyword 'weak'",
        .keyword_if => "the keyword 'if'",
        .keyword_elif => "the keyword 'elif'",
        .keyword_else => "the keyword 'else'",
        .keyword_while => "the keyword 'while'",
        .keyword_for => "the keyword 'for'",
        .keyword_in => "the keyword 'in'",
        .keyword_return => "the keyword 'return'",
        .keyword_break => "the keyword 'break'",
        .keyword_continue => "the keyword 'continue'",
        .keyword_pass => "the keyword 'pass'",
        .keyword_and => "the keyword 'and'",
        .keyword_or => "the keyword 'or'",
        .keyword_not => "the keyword 'not'",
        .keyword_is => "the keyword 'is'",
        .keyword_self => "the keyword 'self'",
        .keyword_true => "'true'",
        .keyword_false => "'false'",
        .keyword_import => "the keyword 'import'",
        .keyword_spawn => "the keyword 'spawn'",
        .keyword_none => "'none'",
        .keyword_try => "the keyword 'try'",
        .keyword_catch => "the keyword 'catch'",
        .keyword_pub => "the keyword 'pub'",

        .int_literal => "a number",
        .float_literal => "a number",
        .char_literal => "a character",
        .string_literal => "a string",
        .fstring => "an f-string",

        .left_paren => "'('",
        .right_paren => "')'",
        .left_bracket => "'['",
        .right_bracket => "']'",
        .left_brace => "'{'",
        .right_brace => "'}'",
        .comma => "','",
        .colon => "':'",
        .dot => "'.'",
        .dot_dot => "'..'",
        .question => "'?'",
        .bang => "'!'",
        .assign => "'='",
        .plus_assign => "'+='",
        .minus_assign => "'-='",
        .star_assign => "'*='",
        .slash_assign => "'/='",
        .slash_slash_assign => "'//='",
        .percent_assign => "'%='",
        .arrow => "'->'",
        .fat_arrow => "'=>'",
        .plus => "'+'",
        .minus => "'-'",
        .ampersand => "'&'",
        .pipe => "'|'",
        .caret => "'^'",
        .tilde => "'~'",
        .shift_left => "'<<'",
        .shift_right => "'>>'",
        .ampersand_assign => "'&='",
        .pipe_assign => "'|='",
        .caret_assign => "'^='",
        .shift_left_assign => "'<<='",
        .shift_right_assign => "'>>='",
        .star => "'*'",
        .slash => "'/'",
        .slash_slash => "'//'",
        .percent => "'%'",
        .equal => "'=='",
        .not_equal => "'!='",
        .less => "'<'",
        .less_equal => "'<='",
        .greater => "'>'",
        .greater_equal => "'>='",
    };
}
