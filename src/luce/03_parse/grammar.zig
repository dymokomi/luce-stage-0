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
const source_mod = @import("../01_source.zig");
const lex_mod = @import("../02_lex.zig");
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
/// byte-order mark (`01_source.prepare`).  Every span this stage
/// produces indexes it.
pub fn parse(
    arena: Allocator,
    temporary: Allocator,
    source: []const u8,
    diagnostics: *Diagnostics,
) Error!ast.Program {
    const tokens = try lex_mod.lex(temporary, source, diagnostics);
    defer temporary.free(tokens);

    var parser: Parser = .{
        .arena = arena,
        .source = source,
        .tokens = tokens,
        .diagnostics = diagnostics,
    };
    return parser.program();
}

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

    pub const max_depth: u32 = 512;

    // Token helpers --------------------------------------------------------

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

    // Recursion bound ------------------------------------------------------

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

    // Diagnostics ----------------------------------------------------------

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

    /// Report "expected `what`, found X" at the offending token — the
    /// token the parser is looking at, never the one after it.
    pub fn expected(self: *Parser, what: []const u8) Error!void {
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
    pub fn sameLine(self: *const Parser, from: usize, to: usize) bool {
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

    // Recovery -------------------------------------------------------------

    /// Resume after a broken construct: drop the rest of the current
    /// line, then drop the indented block that followed it, if any.
    /// The second half is what keeps one missing `:` from turning a
    /// whole function body into nonsense at the outer level.
    pub fn recover(self: *Parser) void {
        self.syncToLine();
        self.skipIndentedBlock();
    }

    /// Skip to the start of the next line at the current block level.
    /// A nested block encountered on the way is consumed whole.
    pub fn syncToLine(self: *Parser) void {
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

    /// The `:` that opens a block body.  A missing one is the commonest
    /// mistake there is in an indentation language, and bailing out
    /// here costs the reader every diagnostic in the body below — the
    /// very cascade the recovery exists to prevent.  So: report it, and
    /// then keep going whenever the *layout* says a block was plainly
    /// meant anyway (a line end followed by an indent).  Returns false
    /// only when there is no body to read on into.
    fn colonOrLayout(self: *Parser, what: []const u8) Error!bool {
        if (self.accept(.colon) != null) return true;
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

    /// Every statement ends at a newline.  When one does not, report
    /// once and drop the rest of the line: parsing the leftovers as a
    /// fresh statement is how a single mistake becomes four.
    fn endOfStatement(self: *Parser, what: []const u8) Error!void {
        if (self.accept(.newline) != null) return;
        if (self.peekKind() == .end_of_file) return;
        try self.expected(what);
        self.recover();
    }

    // Declarations ---------------------------------------------------------

    pub fn program(self: *Parser) Error!ast.Program {
        var imports: std.ArrayList(ast.Import) = .empty;
        defer imports.deinit(self.arena);
        var constants: std.ArrayList(ast.ConstDecl) = .empty;
        defer constants.deinit(self.arena);
        var structs: std.ArrayList(ast.StructDecl) = .empty;
        defer structs.deinit(self.arena);
        var functions: std.ArrayList(ast.FuncDecl) = .empty;
        defer functions.deinit(self.arena);

        while (self.peekKind() != .end_of_file) {
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
                .keyword_struct => {
                    if (try self.structDecl()) |declaration| {
                        try structs.append(self.arena, declaration);
                    } else {
                        self.recover();
                    }
                },
                .keyword_func => {
                    if (try self.funcDecl()) |declaration| {
                        try functions.append(self.arena, declaration);
                    } else {
                        self.recover();
                    }
                },
                .keyword_let => {
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
                        "top-level declarations are let constants; var lives inside functions",
                        .{},
                    );
                    self.recover();
                },
                else => {
                    // A file-scope name is never valid, so a word that
                    // opens a declaration in some *other* language is
                    // the habit rather than a coincidence.  Naming the
                    // Luce spelling beats listing the four keywords.
                    if (self.peekKind() == .identifier) {
                        const word = self.text(self.peek());
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
                        "expected import, let, struct, or func at file scope, found {s}",
                        .{try self.found()},
                    );
                    self.recover();
                },
            }
        }
        return .{
            .imports = try imports.toOwnedSlice(self.arena),
            .constants = try constants.toOwnedSlice(self.arena),
            .structs = try structs.toOwnedSlice(self.arena),
            .functions = try functions.toOwnedSlice(self.arena),
        };
    }

    /// import name — the sibling module `name.luc`; import std.name —
    /// the standard library's.  `std` is the one namespace the grammar
    /// knows, and *what* it contains is stage 1's to say.
    fn importDecl(self: *Parser, imports: *std.ArrayList(ast.Import)) Error!void {
        const start = self.advance(); // import
        const head = (try self.expect(.identifier, "a module name after import")) orelse {
            self.recover();
            return;
        };
        var name = head;
        var origin: source_mod.Origin = .sibling;
        if (self.peekKind() == .dot) {
            // import a.b — there are no import paths, and only the
            // standard library is namespaced (docs/LANGUAGE.md).
            if (!std.mem.eql(u8, self.text(head), source_mod.standard_namespace)) {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "there are no import paths: only the standard library is namespaced, " ++
                        "so write 'import {s}.NAME' for it and 'import {s}' for a module " ++
                        "beside this one",
                    .{ source_mod.standard_namespace, self.text(head) },
                );
                self.recover();
                return;
            }
            _ = self.advance(); // dot
            name = (try self.expect(.identifier, "a standard module name after std.")) orelse {
                self.recover();
                return;
            };
            origin = .standard;
            // import std.a.b — the namespace is one level deep.
            if (self.peekKind() == .dot) {
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "'import {s}.{s}' names one standard module: there are no deeper paths",
                    .{ source_mod.standard_namespace, self.text(name) },
                );
                self.recover();
                return;
            }
        }
        try self.endOfStatement("end of line after the import");
        try imports.append(self.arena, .{
            .name = self.text(name),
            .origin = origin,
            .span = .{ .start = start.span.start, .end = name.span.end },
        });
    }

    /// let name = value at file scope — a constant declaration.
    pub fn constDecl(self: *Parser) Error!?ast.ConstDecl {
        const start = self.advance(); // let
        const name = (try self.expect(.identifier, "a constant name")) orelse return null;
        var annotation: ?ast.TypeName = null;
        if (self.accept(.colon) != null) {
            annotation = (try self.typeName()) orelse return null;
        }
        if ((try self.expect(.assign, "'=' with the constant's value")) == null) return null;
        const value = (try self.expression()) orelse return null;
        try self.endOfStatement("end of line after the constant");
        return .{
            .name = self.text(name),
            .annotation = annotation,
            .value = value,
            .span = .{ .start = start.span.start, .end = value.span().end },
        };
    }

    pub fn typeName(self: *Parser) Error!?ast.TypeName {
        if (!try self.enter("type")) return null;
        defer self.leave();

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
        if (self.peekKind() != .left_paren) return self.optionalSuffix(written);
        const opener = self.advance(); // (

        var arguments: std.ArrayList(ast.TypeName) = .empty;
        defer arguments.deinit(self.arena);
        var wildcards: u8 = 0;
        var previous_end = opener.span.end;
        while (!expr.endsList(self.peekKind(), .right_paren)) {
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
                        "array shape wildcards come last: Array(Int, _, _)",
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
        const closing = (try self.expectClose(.right_paren, opener)) orelse return null;
        written.arguments = try arguments.toOwnedSlice(self.arena);
        written.wildcards = wildcards;
        written.span = .{ .start = item.span.start, .end = closing.span.end };
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

    pub fn structDecl(self: *Parser) Error!?ast.StructDecl {
        const start = self.advance(); // struct
        const name = (try self.expect(.identifier, "a struct name")) orelse return null;
        if (!try self.colonOrLayout("':' after the struct name")) return null;
        if ((try self.expect(.newline, "end of line after ':'")) == null) return null;
        if ((try self.blockBody("struct")) == null) return null;

        var fields: std.ArrayList(ast.Field) = .empty;
        defer fields.deinit(self.arena);
        var functions: std.ArrayList(ast.FuncDecl) = .empty;
        defer functions.deinit(self.arena);
        while (self.peekKind() != .dedent and self.peekKind() != .end_of_file) {
            if (self.accept(.newline) != null) continue;
            if (self.peekKind() == .indent) {
                try self.unexpectedIndent();
                continue;
            }
            if (self.peekKind() == .keyword_func) {
                if (try self.funcDecl()) |declaration| {
                    try functions.append(self.arena, declaration);
                } else {
                    self.recover();
                }
                continue;
            }
            const field_name = (try self.expect(.identifier, "a field name")) orelse {
                self.recover();
                continue;
            };
            if ((try self.expect(.colon, "':' after the field name")) == null) {
                self.recover();
                continue;
            }
            const field_type = (try self.typeName()) orelse {
                self.recover();
                continue;
            };
            try self.endOfStatement("end of line after the field");
            try fields.append(self.arena, .{
                .name = self.text(field_name),
                .type_name = field_type,
                .span = .{ .start = field_name.span.start, .end = field_type.span.end },
            });
        }
        _ = self.accept(.dedent);
        return .{
            .name = self.text(name),
            .fields = try fields.toOwnedSlice(self.arena),
            .functions = try functions.toOwnedSlice(self.arena),
            .span = .{ .start = start.span.start, .end = name.span.end },
        };
    }

    pub fn funcDecl(self: *Parser) Error!?ast.FuncDecl {
        const start = self.advance(); // func
        const name = (try self.expect(.identifier, "a function name")) orelse return null;
        const opener = (try self.expect(.left_paren, "'(' opening the parameter list")) orelse
            return null;

        var parameters: std.ArrayList(ast.Parameter) = .empty;
        defer parameters.deinit(self.arena);
        var previous_end = opener.span.end;
        while (!expr.endsList(self.peekKind(), .right_paren)) {
            const parameter_name = (try self.expect(.identifier, "a parameter name")) orelse
                return null;
            if ((try self.expect(.colon, "':' after the parameter name")) == null) return null;
            const mode: ast.ParameterMode = if (self.accept(.keyword_give) != null) .give else .borrow;
            const parameter_type = (try self.typeName()) orelse return null;
            try parameters.append(self.arena, .{
                .name = self.text(parameter_name),
                .mode = mode,
                .type_name = parameter_type,
                .span = .{ .start = parameter_name.span.start, .end = parameter_type.span.end },
            });
            previous_end = parameter_type.span.end;
            if (self.accept(.comma) == null) break;
        }
        if (try self.missingSeparator(previous_end)) return null;
        if ((try self.expectClose(.right_paren, opener)) == null) return null;

        var return_type: ?ast.TypeName = null;
        if (self.accept(.arrow) != null) {
            return_type = (try self.typeName()) orelse return null;
        }
        const body = (try self.block("func")) orelse return null;
        return .{
            .name = self.text(name),
            .parameters = try parameters.toOwnedSlice(self.arena),
            .return_type = return_type,
            .body = body,
            .span = .{ .start = start.span.start, .end = name.span.end },
        };
    }

    // Statements -----------------------------------------------------------

    /// The `: NEWLINE INDENT …` body of a header.  `opener` names the
    /// keyword that opened it, so a missing or empty body can say which
    /// header is waiting for statements rather than which token the
    /// parser wanted.
    pub fn block(self: *Parser, opener: []const u8) Error!?ast.Block {
        if (!try self.colonOrLayout("':' to open the block")) return null;
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

    pub fn statement(self: *Parser) Error!?ast.Statement {
        if (!try self.enter("block")) return null;
        defer self.leave();

        switch (self.peekKind()) {
            .keyword_let => return self.binding(false),
            .keyword_var => return self.binding(true),
            .keyword_if => return self.conditional(),
            .keyword_while => return self.whileLoop(),
            .keyword_for => return self.forLoop(),
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
            .keyword_func, .keyword_struct, .keyword_import => {
                const word = keywordWord(self.peekKind()).?;
                try self.report(
                    "luce.parse.expected",
                    self.peek().span,
                    "'{s}' declarations belong at file scope, not inside a function",
                    .{word},
                );
                return null;
            },
            else => return self.assignOrExpression(),
        }
    }

    pub fn binding(self: *Parser, mutable: bool) Error!?ast.Statement {
        const start = self.advance(); // let or var
        const name = (try self.expect(.identifier, "a binding name")) orelse return null;
        var annotation: ?ast.TypeName = null;
        if (self.accept(.colon) != null) {
            annotation = (try self.typeName()) orelse return null;
        }
        // var name: Type — a late declaration; the slot starts at the
        // type's zero value (OWNERSHIP.md S40).  let always initializes.
        if (mutable and annotation != null and self.peekKind() == .newline) {
            _ = self.advance();
            return .{ .variable = .{
                .name = self.text(name),
                .annotation = annotation,
                .value = null,
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
        try self.endOfStatement("end of line after the binding");
        const span: Span = .{ .start = start.span.start, .end = value.span().end };
        if (mutable) {
            return .{ .variable = .{
                .name = self.text(name),
                .annotation = annotation,
                .value = value,
                .span = span,
            } };
        }
        return .{ .let = .{
            .name = self.text(name),
            .annotation = annotation,
            .value = value,
            .span = span,
        } };
    }

    pub fn conditional(self: *Parser) Error!?ast.Statement {
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

    pub fn whileLoop(self: *Parser) Error!?ast.Statement {
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

    pub fn forLoop(self: *Parser) Error!?ast.Statement {
        const start = self.advance();
        const name = (try self.expect(.identifier, "a loop variable")) orelse return null;
        // for key, value in ...: — an optional second binding.  A
        // two-name loop is never a range, so this precedes that check.
        var value_name: ?[]const u8 = null;
        var value_token: ?Token = null;
        if (self.accept(.comma) != null) {
            const second = (try self.expect(.identifier, "a second loop variable")) orelse return null;
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

    pub fn returnStatement(self: *Parser) Error!?ast.Statement {
        const start = self.advance();
        if (self.accept(.newline) != null) {
            return .{ .return_statement = .{ .value = null, .span = start.span } };
        }
        const value = (try self.expression()) orelse return null;
        try self.endOfStatement("end of line after return");
        return .{ .return_statement = .{
            .value = value,
            .span = .{ .start = start.span.start, .end = value.span().end },
        } };
    }

    // PLACE = expression, or a bare expression statement.  The place
    // is parsed as an ordinary expression and then classified: a name,
    // one dotted field on a name, or an indexed expression.
    pub fn assignOrExpression(self: *Parser) Error!?ast.Statement {
        const left = (try self.expression()) orelse return null;
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
            try self.endOfStatement("end of line after the expression");
            return .{ .expression = .{ .value = left, .span = left.span() } };
        }
        _ = self.advance(); // '=' or 'OP='

        const target = (try self.targetFrom(left)) orelse return null;
        const value = (try self.expression()) orelse return null;
        try self.endOfStatement("end of line after the assignment");
        return .{ .assign = .{
            .target = target,
            .compound = compound,
            .value = value,
            .span = .{ .start = target.span().start, .end = value.span().end },
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
            .percent_assign => .remainder,
            else => null,
        };
    }

    pub fn targetFrom(self: *Parser, left: *ast.Expression) Error!?ast.Target {
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

    // Expression entry — delegates to expressions.zig.
    pub fn expression(self: *Parser) Error!?*ast.Expression {
        return expr.expression(self);
    }

    pub fn make(self: *Parser, value: ast.Expression) Error!*ast.Expression {
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
fn foreignWord(word: []const u8) ?[]const u8 {
    const import_advice = "imports name one module: 'import name' for a file beside " ++
        "this one, 'import " ++ source_mod.standard_namespace ++ ".name' for the standard library";
    const habits = [_]struct { word: []const u8, advice: []const u8 }{
        .{ .word = "elseif", .advice = "write 'elif': Luce chains conditions with one keyword" },
        .{ .word = "elsif", .advice = "write 'elif': Luce chains conditions with one keyword" },
        .{ .word = "foreach", .advice = "loops are written 'for x in xs:'" },
        .{ .word = "switch", .advice = "there is no switch; chain 'if' and 'elif'" },
        .{ .word = "case", .advice = "there is no switch; chain 'if' and 'elif'" },
        .{ .word = "def", .advice = "functions are declared with 'func'" },
        .{ .word = "fn", .advice = "functions are declared with 'func'" },
        .{ .word = "fun", .advice = "functions are declared with 'func'" },
        .{ .word = "function", .advice = "functions are declared with 'func'" },
        .{ .word = "class", .advice = "there are no classes; 'struct' declares a value type" },
        .{ .word = "type", .advice = "there are no type aliases; 'struct' declares a value type" },
        .{ .word = "enum", .advice = "there are no enums; 'struct' declares a value type" },
        .{ .word = "const", .advice = "file-scope constants are declared with 'let'" },
        .{ .word = "final", .advice = "file-scope constants are declared with 'let'" },
        .{ .word = "from", .advice = import_advice },
        .{ .word = "include", .advice = import_advice },
        .{ .word = "require", .advice = import_advice },
        .{ .word = "use", .advice = import_advice },
        .{ .word = "pub", .advice = "there is no visibility keyword: every declaration is importable" },
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
        .keyword_struct => "the keyword 'struct'",
        .keyword_let => "the keyword 'let'",
        .keyword_var => "the keyword 'var'",
        .keyword_if => "the keyword 'if'",
        .keyword_elif => "the keyword 'elif'",
        .keyword_else => "the keyword 'else'",
        .keyword_while => "the keyword 'while'",
        .keyword_for => "the keyword 'for'",
        .keyword_in => "the keyword 'in'",
        .keyword_return => "the keyword 'return'",
        .keyword_break => "the keyword 'break'",
        .keyword_continue => "the keyword 'continue'",
        .keyword_and => "the keyword 'and'",
        .keyword_or => "the keyword 'or'",
        .keyword_not => "the keyword 'not'",
        .keyword_true => "'true'",
        .keyword_false => "'false'",
        .keyword_new => "the keyword 'new'",
        .keyword_import => "the keyword 'import'",
        .keyword_give => "the keyword 'give'",
        .keyword_copy => "the keyword 'copy'",
        .keyword_none => "'none'",

        .int_literal => "a number",
        .float_literal => "a number",
        .string_literal => "a string",
        .fstring => "an f-string",

        .left_paren => "'('",
        .right_paren => "')'",
        .left_bracket => "'['",
        .right_bracket => "']'",
        .comma => "','",
        .colon => "':'",
        .dot => "'.'",
        .question => "'?'",
        .assign => "'='",
        .plus_assign => "'+='",
        .minus_assign => "'-='",
        .star_assign => "'*='",
        .slash_assign => "'/='",
        .percent_assign => "'%='",
        .arrow => "'->'",
        .plus => "'+'",
        .minus => "'-'",
        .star => "'*'",
        .slash => "'/'",
        .percent => "'%'",
        .equal => "'=='",
        .not_equal => "'!='",
        .less => "'<'",
        .less_equal => "'<='",
        .greater => "'>'",
        .greater_equal => "'>='",
    };
}
