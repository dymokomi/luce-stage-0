//! The Luce lexer: bytes to tokens plus indentation structure.
//!
//! ## Its input is stage 1's prepared text
//!
//! `lex()` is not a byte-hygiene gate and does not duplicate one.
//! Stage 1 (`source/encoding.zig`) already decided what a *file*
//! may be — no BOM, no NUL, no carriage return of any kind, valid
//! UTF-8, within `max_bytes` — and every path into the compiler goes
//! through it.  So this file starts from those guarantees rather than
//! re-checking them: there is no CRLF handling here, no `luce.lex.utf8`
//! code, and no lone-CR diagnostic, because those states cannot exist
//! in a prepared buffer.  The precondition is asserted on entry in
//! Debug builds (`isPrepared`), so a caller that skips stage 1 fails
//! loudly at the seam instead of quietly getting different answers
//! from two layers.  Stage 1 owns encoding; stage 2 owns *meaning*.
//!
//! What stage 1 deliberately leaves here is everything a *program* can
//! be wrong about, including bytes that are perfectly valid UTF-8 and
//! still have no business in source: control characters, form feeds,
//! Unicode look-alikes, and the bidirectional controls below.
//!
//! ## The lexical surface
//!
//! * **Numbers** are decimal.  `12`, `1.5`, `1e10`, `1.5e-3`; a `.`
//!   only starts a fraction when a digit follows, so `1.` is `1` then
//!   `.`, and a leading `.5` is a `luce.lex.number` diagnostic rather
//!   than a dot glued to an integer.  A decimal integer may not carry
//!   a leading zero — `0755` is not octal in Luce and must not be
//!   allowed to look as though it might be (CPython's rule, for
//!   CPython's reason).  Hexadecimal, binary, octal and digit
//!   separators are *not* in the language (docs/MISSING.md tier 2,
//!   item 13) — writing one is a `luce.lex.number` diagnostic that
//!   names the reason.  The lexer does not evaluate literals, so range
//!   is stage 4's call (`luce.sema.literal`).
//! * **Strings** are `"..."` on one line, with exactly four escapes:
//!   `\n`, `\t`, `\\`, `\"`.  Anything else after a backslash is a
//!   `luce.lex.escape` diagnostic.  `f"..."` is scanned whole and
//!   expanded by the parser.  **Characters** are single-quoted and
//!   become one Unicode scalar; this stage keeps the quoted run whole
//!   and stage 3 validates and decodes it, including `\u{...}`.
//! * **Identifiers** are ASCII: a letter or `_`, then letters, digits
//!   or `_`.  A stray non-ASCII character is one diagnostic per
//!   *codepoint*, naming its `U+XXXX` — and for the look-alikes people
//!   actually paste (curly quotes, en dashes, non-breaking spaces,
//!   fullwidth punctuation, `≠`), naming the ASCII spelling to use.
//! * **Bidirectional controls** (U+061C, U+200E/200F, U+202A-U+202E,
//!   U+2066-U+2069) are refused *everywhere*, including inside strings
//!   and comments, as `luce.lex.bidi`.  They reorder how a line renders
//!   without changing what it means, which is exactly the Trojan Source
//!   attack (CVE-2021-42574): source that reads one way and runs
//!   another.  A program that genuinely needs one in its text builds it
//!   with `str(char(codepoint))`.
//! * **Comments** run from `#` to the end of the line; there is no
//!   block comment form.  A `#!` first line therefore works by
//!   construction.  `/* ... */` is a `luce.lex.comment` diagnostic
//!   that skips what its author meant to comment out, rather than
//!   arithmetic that fails three tokens later.  `//` used to be one
//!   too and is now **floor division** (docs/NUMERICS.md); a line
//!   that begins with it is answered by the parser, which is the only
//!   place the comment reading is unambiguous.
//! * **Line endings** are LF: stage 1 has already folded CRLF and
//!   refused a lone CR.
//! * **Layout** is indentation, and the four-space step is *enforced*,
//!   not merely canonical: a block opens exactly four columns deeper
//!   than the one containing it (`luce.lex.indent` otherwise).  Tabs
//!   are rejected outright — no `TabError`-style "consistent use is
//!   fine" rule to reason about — and blank or comment-only lines
//!   produce no layout tokens.  Inside parentheses, brackets, and map
//!   literal braces, newlines and indentation are plain spacing, so
//!   calls and expressions may span lines.  F-string braces are
//!   scanned inside their single token and never enter this layout
//!   depth.  Nesting is bounded by
//!   `max_indent_depth`.
//!
//! ## The recovery contract
//!
//! The lexer never fails hard, and one bad construct must not silence
//! the rest of the file.  Three rules make that true:
//!
//! 1. Every malformed construct is reported and then *skipped* — the
//!    scanner always advances, so there is no way to loop.
//! 2. Where a value was clearly intended, a **recovery token** is
//!    emitted anyway (the leading digits of a bad number, the text of
//!    an unterminated string, a `'...'` run mistaken for a string), so
//!    the parser sees one error instead of two.  Recovery tokens only
//!    ever appear alongside a diagnostic, and a diagnostic means the
//!    program is rejected before analysis, so their contents are never
//!    observable in a compiled program — which is why a `string_literal`
//!    token is allowed to hold text that is not a well-formed string.
//! 3. Reporting is bounded twice over.  A run of the *same* stray
//!    character is one message carrying its length, so four thousand
//!    junk bytes read as one mistake (rustc's `swallow_next_invalid`);
//!    and whatever survives that is capped at `max_diagnostics`, so a
//!    megabyte of varied noise is a hundred messages plus one
//!    `luce.lex.limit`.  Memory use stays proportional to what a human
//!    can read.
//!
//! The codes this stage can produce, in full: `luce.lex.tab`,
//! `luce.lex.indent`, `luce.lex.number`, `luce.lex.str`,
//! `luce.lex.escape`, `luce.lex.character`, `luce.lex.comment`,
//! `luce.lex.bidi`, `luce.lex.name`, `luce.lex.limit`.
//!
//! ## Deliberately not here
//!
//! * **More string escapes.**  `\r` and `\u{...}` are both defensible
//!   additions to strings, and both are *half* in this file: the lexer
//!   only validates an escape, stage 3's `decodeString` produces the
//!   bytes.  Adding one here without the decoder would silently produce
//!   wrong text, so the escape set moves as one change across two stages
//!   or not at all.  `\xNN` is refused permanently for a different
//!   reason: a raw byte escape can build a string that is not UTF-8,
//!   and every other layer is allowed to assume it is.

const std = @import("std");
const builtin = @import("builtin");
const source_mod = @import("../source.zig");
const token_mod = @import("token.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const Token = token_mod.Token;
const Kind = token_mod.Kind;
const Diagnostics = diagnostics_mod.Diagnostics;

pub const Error = error{OutOfMemory};

/// How much deeper a block sits than the one containing it.  Enforced,
/// not merely canonical: a language whose blocks *are* their
/// indentation cannot leave the size of a step to taste, or two files
/// that look alike mean different things.  Tabs are already refused
/// outright, so this is the last freedom that could make a column
/// ambiguous, and it costs one comparison to close.
const indent_step = 4;

/// What one rejected tab stands in for while recovering: the next
/// four-column stop, so a tab-indented file still gets the block
/// structure its author meant.
const tab_width = indent_step;

/// How deep blocks may nest.  CPython's `MAXINDENT`, for CPython's
/// reason: the indent stack is the one piece of lexer state that grows
/// with the input, and a generated file of ever-deeper lines should
/// meet a diagnostic rather than an allocator.  A hundred levels is
/// four hundred columns — far past anything a human writes.
const max_indent_depth = 100;

/// How many lexical diagnostics one `lex()` call reports before it
/// falls silent with a single `luce.lex.limit`.  Generous for real
/// source, tight enough that a file of noise cannot turn into
/// gigabytes of error text.
const max_diagnostics = 100;

/// Lex the whole buffer.  The returned tokens borrow nothing; the
/// caller owns the slice.  Malformed input is reported through the
/// diagnostics and skipped.
///
/// **Precondition:** `source` is stage 1's prepared text — valid
/// UTF-8, LF line endings, no lone carriage return, no NUL, no leading
/// byte-order mark (`source.prepare`).  Every path into the
/// compiler passes through that gate, and this stage is written to its
/// guarantees rather than re-deciding them; Debug builds check the
/// precondition here so a caller that skips stage 1 fails at the seam.
pub fn lex(allocator: Allocator, source: []const u8, diagnostics: *Diagnostics) Error!Lexed {
    if (builtin.mode == .Debug and !isPrepared(source)) std.debug.panic(
        "lex() was handed raw bytes: its input must come from source.prepare",
        .{},
    );
    var lexer: Lexer = .{
        .allocator = allocator,
        .source = source,
        .diagnostics = diagnostics,
    };
    defer lexer.indents.deinit(allocator);
    errdefer lexer.tokens.deinit(allocator);
    try lexer.run();
    return .{
        .tokens = try lexer.tokens.toOwnedSlice(allocator),
        .truncated = lexer.truncated,
    };
}

/// What a lex produced.
pub const Lexed = struct {
    /// The tokens, always ending in `end_of_file` with every block
    /// closed.  The caller owns the slice.
    tokens: []Token,
    /// True when a structural bound — the nesting depth — stopped the
    /// scan before the end of the source.  The tokens are still well
    /// formed, but the tail of them is this stage's own closing-up
    /// rather than anything the author wrote, so **a stage that
    /// reports on them must add nothing**: the file was refused, by
    /// name, once already, and a hundred-deep nest closed by force
    /// ends in a block that looks empty because the lexer stopped.
    truncated: bool = false,
};

/// Whether `source` satisfies `lex()`'s precondition.  Only Debug
/// builds pay for this: it is a second pass over the input, and its
/// job is to catch a *programming* mistake — a caller that bypassed
/// stage 1 — not to handle a bad file, which stage 1 already does with
/// a diagnostic.
pub fn isPrepared(source: []const u8) bool {
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) return false;
    var offset: usize = 0;
    while (offset < source.len) {
        const first = source[offset];
        if (first == 0 or first == '\r') return false;
        if (first < 0x80) {
            offset += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(first) catch return false;
        if (offset + length > source.len) return false;
        _ = std.unicode.utf8Decode(source[offset..][0..length]) catch return false;
        offset += length;
    }
    return true;
}

const Lexer = struct {
    allocator: Allocator,
    source: []const u8,
    diagnostics: *Diagnostics,
    tokens: std.ArrayList(Token) = .empty,
    /// The open indentation columns, innermost last; always starts
    /// with 0, so it is never empty.
    indents: std.ArrayList(usize) = .empty,
    offset: usize = 0,
    /// Open `(`, `[`, and map-literal `{` together: layout is
    /// suspended while any are open.  F-string holes are scanned whole
    /// by `fstring()` and keep their own independent brace depth.
    paren_depth: usize = 0,
    at_line_start: bool = true,
    /// Diagnostics this lexer has added, for the `max_diagnostics`
    /// cap.  Counted here rather than read from `diagnostics`, which
    /// may already hold other modules' errors.
    reported: usize = 0,
    /// Set when a structural bound stopped the scan before the end of
    /// the source.  What follows in the token stream is this stage's
    /// own closing-up, so the next stage must add nothing about it.
    truncated: bool = false,

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

    // -- diagnostics ------------------------------------------------------

    /// Add one lexical diagnostic, honoring the report cap.  Every
    /// diagnostic in this file goes through here; the scanner keeps
    /// running either way, so the token stream never depends on how
    /// many errors came before.
    fn report(
        self: *Lexer,
        code: []const u8,
        span: Span,
        comptime format: []const u8,
        arguments: anytype,
    ) Error!void {
        if (self.reported > max_diagnostics) return;
        if (self.reported == max_diagnostics) {
            self.reported += 1;
            try self.diagnostics.add(
                "luce.lex.limit",
                span,
                "too many lexical errors; only the first {d} are reported",
                .{max_diagnostics},
            );
            return;
        }
        self.reported += 1;
        try self.diagnostics.add(code, span, format, arguments);
    }

    // -- layout -----------------------------------------------------------

    /// Whether the line ends at `at`.  Stage 1 folded CRLF, so there
    /// is exactly one line terminator to know about.
    fn atLineBreak(self: *const Lexer, at: usize) bool {
        return at < self.source.len and self.source[at] == '\n';
    }

    /// Measure indentation and emit indent/dedent when it changes.
    /// Blank and comment-only lines are layout-free.
    fn lineStart(self: *Lexer) Error!void {
        const line_begin = self.offset;
        var width: usize = 0;
        var tab_begin: ?usize = null;
        var tab_end: usize = 0;
        while (self.offset < self.source.len) {
            const character = self.source[self.offset];
            if (character == ' ') {
                width += 1;
                self.offset += 1;
            } else if (character == '\t') {
                if (tab_begin == null) tab_begin = self.offset;
                self.offset += 1;
                tab_end = self.offset;
                // Recovery: a rejected tab still stands for the next
                // four-column stop, so a tab-indented file gets the
                // block structure its author meant and one error per
                // line rather than a cascade of parse failures.
                width = (width / tab_width + 1) * tab_width;
            } else break;
        }
        // One diagnostic per line, however many tabs it used.
        if (tab_begin) |begin| {
            try self.report(
                "luce.lex.tab",
                .{ .start = begin, .end = tab_end },
                "tabs are not allowed; indent with four spaces",
                .{},
            );
        }
        if (self.offset >= self.source.len) return;

        if (self.atLineBreak(self.offset)) {
            self.offset += 1;
            return; // blank line
        }
        if (self.source[self.offset] == '#') {
            try self.skipComment();
            if (self.atLineBreak(self.offset)) self.offset += 1;
            return; // comment-only line
        }

        const current = self.indents.items[self.indents.items.len - 1];
        const here: Span = .{ .start = line_begin, .end = self.offset };
        if (width > current) {
            if (self.indents.items.len >= max_indent_depth) {
                // A structural bound is one condition, not one per
                // line that breaks it: report it once and stop, the
                // way the parser's `nesting_reported` does.  Joining
                // each over-deep line to the innermost open block
                // instead used to report per line *and* leave the
                // parser a stream of bodyless block headers to
                // complain about — 62 diagnostics and 65 KB for one
                // mistake.  Every block still closes below, so the
                // token stream stays well formed.
                // The caret goes on the block being opened, not on the
                // indentation `here` covers: the other two messages on
                // this line are *about* the whitespace, and this one
                // is not — a caret under four hundred columns of
                // spaces tells the reader nothing.
                try self.report(
                    "luce.lex.indent",
                    .{ .start = self.offset, .end = self.offset + 1 },
                    "blocks may not nest more than {d} deep",
                    .{max_indent_depth},
                );
                self.truncated = true;
                self.offset = self.source.len;
                return;
            }
            // A tab already explains an odd column; do not say it
            // twice.  One cause, one diagnostic.
            if (tab_begin == null and width != current + indent_step) {
                try self.report(
                    "luce.lex.indent",
                    here,
                    "a block is indented exactly {d} spaces past the one containing it, not {d}",
                    .{ indent_step, width - current },
                );
            }
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
                try self.report(
                    "luce.lex.indent",
                    here,
                    "indentation does not match any open block",
                    .{},
                );
            }
        }
        self.at_line_start = false;
    }

    // -- the scanner ------------------------------------------------------

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
                const begin = self.offset;
                while (self.offset < self.source.len and self.source[self.offset] == '\t') {
                    self.offset += 1;
                }
                try self.report(
                    "luce.lex.tab",
                    .{ .start = begin, .end = self.offset },
                    "tabs are not allowed",
                    .{},
                );
            },
            '\n' => {
                self.offset += 1;
                if (self.paren_depth == 0) {
                    try self.emit(.newline, .{ .start = self.offset - 1, .end = self.offset });
                    self.at_line_start = true;
                }
            },
            '#' => try self.skipComment(),
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
            '{' => {
                self.paren_depth += 1;
                try self.single(.left_brace);
            },
            '}' => {
                if (self.paren_depth > 0) self.paren_depth -= 1;
                try self.single(.right_brace);
            },
            ',' => try self.single(.comma),
            ':' => try self.single(.colon),
            '?' => try self.single(.question),
            '.' => {
                // A `.` is followed by a name (member access) or by
                // nothing in particular.  A digit after it is one of
                // two mistakes, and which one depends on what came
                // before: a number just emitted makes this a second
                // decimal point, and anything else makes it the `.5`
                // fraction with nothing in front of it.
                if (!isDigit(self.peek(1))) {
                    try self.single(.dot);
                } else if (self.afterNumberLiteral()) {
                    try self.extraDecimalPoint();
                } else {
                    try self.leadingPointNumber();
                }
            },
            '+' => try self.maybeAssign(.plus, .plus_assign),
            '*' => try self.maybeAssign(.star, .star_assign),
            '/' => try self.slashSomething(),
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
                    // A lone `!` is the fallibility mark on a return
                    // type and nothing else; the parser is where it
                    // has to be one.
                    try self.single(.bang);
                }
            },
            '<' => {
                if (self.peek(1) == '<') {
                    try self.shiftOperator(.shift_left, .shift_left_assign);
                } else if (self.peek(1) == '=') {
                    try self.emit(.less_equal, .{ .start = self.offset, .end = self.offset + 2 });
                    self.offset += 2;
                } else {
                    try self.single(.less);
                }
            },
            '>' => {
                if (self.peek(1) == '>') {
                    try self.shiftOperator(.shift_right, .shift_right_assign);
                } else if (self.peek(1) == '=') {
                    try self.emit(.greater_equal, .{ .start = self.offset, .end = self.offset + 2 });
                    self.offset += 2;
                } else {
                    try self.single(.greater);
                }
            },
            '&' => try self.maybeAssign(.ampersand, .ampersand_assign),
            '|' => try self.maybeAssign(.pipe, .pipe_assign),
            '^' => try self.maybeAssign(.caret, .caret_assign),
            '~' => try self.single(.tilde),
            '"' => try self.string(),
            '\'' => try self.characterLiteral(),
            '0'...'9' => try self.number(),
            'a'...'z', 'A'...'Z', '_' => try self.word(),
            else => if (character >= 0x80) try self.foreignCharacter() else try self.unexpectedCharacter(),
        }
    }

    /// The byte `ahead` past the cursor, or 0 at the end of input.
    /// Zero is a safe sentinel because stage 1 refuses a NUL byte, so
    /// it can never be a real character.
    fn peek(self: *const Lexer, ahead: usize) u8 {
        if (self.offset + ahead >= self.source.len) return 0;
        return self.source[self.offset + ahead];
    }

    fn single(self: *Lexer, kind: Kind) Error!void {
        try self.emit(kind, .{ .start = self.offset, .end = self.offset + 1 });
        self.offset += 1;
    }

    /// `<<` / `<<=` and `>>` / `>>=`: two characters already read as
    /// the operator, with an optional `=` behind them.
    fn shiftOperator(self: *Lexer, bare: Kind, compound: Kind) Error!void {
        if (self.peek(2) == '=') {
            try self.emit(compound, .{ .start = self.offset, .end = self.offset + 3 });
            self.offset += 3;
        } else {
            try self.emit(bare, .{ .start = self.offset, .end = self.offset + 2 });
            self.offset += 2;
        }
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

    /// Advance to the newline that ends the line, leaving it in place.
    /// A comment's *meaning* is never inspected, but the two things
    /// that are wrong wherever they appear still are: a byte with no
    /// glyph, and a control that reorders how the line renders.  A
    /// comment is the classic hiding place for both.
    fn skipComment(self: *Lexer) Error!void {
        while (self.offset < self.source.len) : (self.offset += 1) {
            const character = self.source[self.offset];
            if (character == '\n') return;
            if (character >= 0x20 and character < 0x7f) continue;
            try self.checkTextByte(self.offset);
        }
    }

    /// The three things a `/` can begin.
    ///
    /// `//` is **floor division** (docs/NUMERICS.md), which is what it
    /// costs to have that operator: this used to be the place a
    /// reader who wrote a C-style comment was told there is no `//`
    /// form, and the message served exactly the newcomer the operator
    /// is otherwise courting.  It is not gone, it has moved — a line
    /// that *starts* with `//` cannot be arithmetic, and the parser
    /// says so where it meets one (`luce.parse.comment`).  That is the
    /// only position the mistake is unambiguous in, and the one it is
    /// nearly always made in.
    ///
    /// `/* ... */` keeps its arm and its diagnostic: nothing in the
    /// language claims it, so it can still be named and skipped the
    /// way its author meant it to be read.
    fn slashSomething(self: *Lexer) Error!void {
        const start = self.offset;
        switch (self.peek(1)) {
            '/' => {
                if (self.peek(2) == '=') {
                    try self.emit(.slash_slash_assign, .{ .start = start, .end = start + 3 });
                    self.offset += 3;
                } else {
                    try self.emit(.slash_slash, .{ .start = start, .end = start + 2 });
                    self.offset += 2;
                }
            },
            '*' => {
                try self.report(
                    "luce.lex.comment",
                    .{ .start = start, .end = start + 2 },
                    "block comments are not in the language; a comment runs from '#' to the end of the line",
                    .{},
                );
                // Skip what the author meant to comment out, so the
                // mistake costs one message rather than one per line
                // of prose inside it.
                self.offset = if (std.mem.indexOfPos(u8, self.source, start + 2, "*/")) |found|
                    found + 2
                else
                    self.source.len;
            },
            else => try self.maybeAssign(.slash, .slash_assign),
        }
    }

    /// One byte of literal or comment text.  Two things are wrong
    /// there no matter what the text says: a raw control byte, which
    /// is invisible and has an escape if it was meant, and a
    /// bidirectional control, which makes the line render in an order
    /// it does not run in.
    fn checkTextByte(self: *Lexer, at: usize) Error!void {
        const character = self.source[at];
        if (character < 0x80) {
            if (character == '\t') {
                try self.report(
                    "luce.lex.tab",
                    .{ .start = at, .end = at + 1 },
                    "tabs are not allowed; write \\t for a tab in text",
                    .{},
                );
            } else if (character < 0x20 or character == 0x7f) {
                try self.report(
                    "luce.lex.character",
                    .{ .start = at, .end = at + 1 },
                    "unexpected control byte 0x{X:0>2}",
                    .{character},
                );
            }
            return;
        }
        if (bidiControlAt(self.source, at)) |codepoint| try self.reportBidi(at, codepoint);
    }

    /// One `luce.lex.bidi`.  Every bidirectional control is two or
    /// three bytes, and only U+061C is two.
    fn reportBidi(self: *Lexer, at: usize, codepoint: u21) Error!void {
        const length: usize = if (codepoint == 0x061C) 2 else 3;
        try self.report(
            "luce.lex.bidi",
            .{ .start = at, .end = @min(at + length, self.source.len) },
            "U+{X:0>4} is a bidirectional control: it changes how this line reads without changing what it does; build the text with str(char({d})) if it is really needed",
            .{ codepoint, codepoint },
        );
    }

    /// Scan a name: ASCII letters, digits and `_`.
    ///
    /// While recovering it also swallows the non-ASCII characters glued
    /// to them, so `café` is one misspelled name and one diagnostic
    /// rather than `caf`, a stray character, and whatever the parser
    /// makes of the pieces (rustc's `InvalidIdent`, for the same
    /// reason).  The token is emitted either way — the parser should
    /// see the declaration the author wrote.
    fn word(self: *Lexer) Error!void {
        const start = self.offset;
        var foreign: ?usize = null;
        while (self.offset < self.source.len) {
            const character = self.source[self.offset];
            if (isWordPart(character)) {
                self.offset += 1;
                continue;
            }
            if (character < 0x80) break; // the ordinary end of a name
            const length = namePartLength(self.source, self.offset) orelse break;
            if (foreign == null) foreign = self.offset;
            self.offset += length;
        }
        const span: Span = .{ .start = start, .end = self.offset };
        if (foreign) |at| {
            const length = namePartLength(self.source, at).?;
            try self.report(
                "luce.lex.character",
                .{ .start = at, .end = at + length },
                "'{s}' cannot be part of a name; names are ASCII letters, digits and '_'",
                .{self.source[at..][0..length]},
            );
            try self.emit(.identifier, span);
            return;
        }
        // A name starts with a letter [VISIBILITY.md R3].  The lone `_`
        // passes through — it is the array-shape wildcard, contextually
        // recognised by the type parser, and never a name.  Interior and
        // trailing underscores are the house style and untouched.  The
        // token is still emitted: a refused word is a reported word, and
        // the parser should see the declaration the author wrote.
        const text = span.slice(self.source);
        if (text.len > 1 and text[0] == '_') {
            try self.report(
                "luce.lex.name",
                span,
                "a name starts with a letter: {s} is not a name",
                .{text},
            );
            try self.emit(.identifier, span);
            return;
        }
        const kind = token_mod.keyword_map.get(text) orelse .identifier;
        try self.emit(kind, span);
    }

    // -- numbers ----------------------------------------------------------

    /// Scan a decimal literal.  On a malformed one — a radix prefix, a
    /// digit separator, letters glued to the digits — the whole run is
    /// one diagnostic naming the reason, and the well-formed prefix is
    /// still emitted so the parser has an operand.
    fn number(self: *Lexer) Error!void {
        const start = self.offset;
        // `0x` and `0b` open the two non-decimal bases the language
        // has (docs/BITWISE.md R3); octal stays refused by name below.
        if (self.source[start] == '0' and
            (self.peek(1) == 'x' or self.peek(1) == 'X' or
                self.peek(1) == 'b' or self.peek(1) == 'B'))
        {
            return self.basedNumber(if (self.peek(1) == 'x' or self.peek(1) == 'X')
                .hex
            else
                .binary);
        }
        while (self.offset < self.source.len and
            (isDigit(self.source[self.offset]) or self.source[self.offset] == '_'))
        {
            self.offset += 1;
        }
        const integer_end = self.offset;
        var is_float = false;
        if (self.offset < self.source.len and self.source[self.offset] == '.' and
            self.offset + 1 < self.source.len and isDigit(self.source[self.offset + 1]))
        {
            is_float = true;
            self.offset += 1;
            while (self.offset < self.source.len and
                (isDigit(self.source[self.offset]) or self.source[self.offset] == '_'))
            {
                self.offset += 1;
            }
        }
        // `1.` — a point with no fraction and nothing that could be a
        // member name after it.  The dot used to be left for the
        // parser, which answered "expected a field or function name
        // after '.', found end of line" about what is plainly an
        // unfinished float; `.5` has had the model message all along.
        // A word start after the point really is member access
        // (`5.foo`), and i64 saying it has no fields is the right
        // answer to that one, so it is left alone.
        var unfinished_point = false;
        if (!is_float and self.offset < self.source.len and self.source[self.offset] == '.' and
            !isWordStart(self.peek(1)))
        {
            unfinished_point = true;
            is_float = true;
            self.offset += 1;
        }
        const before_exponent = self.offset;
        self.scanExponent();
        if (self.offset != before_exponent) is_float = true;
        const span: Span = .{ .start = start, .end = self.offset };
        if (unfinished_point) {
            try self.report(
                "luce.lex.number",
                span,
                "a float needs a digit after the point; write {s}0",
                .{span.slice(self.source)},
            );
            try self.emit(.float_literal, span);
            return;
        }

        // Separators sit between digits and nowhere else
        // (docs/BITWISE.md D7): never doubled, never at either end of
        // a digit run, never beside the point or the exponent mark.
        if (try self.misplacedSeparator(span)) {
            try self.emit(if (is_float) .float_literal else .int_literal, span);
            return;
        }

        // A literal glued to identifier characters is one malformed
        // number, not a number and a word.
        if (self.offset < self.source.len and isWordStart(self.source[self.offset])) {
            while (self.offset < self.source.len and isWordPart(self.source[self.offset])) {
                self.offset += 1;
            }
            const whole: Span = .{ .start = start, .end = self.offset };
            try self.report(
                "luce.lex.number",
                whole,
                "malformed numeric literal: {s}",
                .{numberProblem(whole.slice(self.source))},
            );
        } else if (!is_float and integer_end - start >= 2 and self.source[start] == '0') {
            // `0755` means seven hundred and fifty-five here and four
            // hundred and ninety-three in C.  Luce has no octal
            // literals at all, so the only thing a leading zero can do
            // is mislead — CPython refuses it for exactly this reason,
            // and points at the zeros rather than the whole literal.
            var zeros_end = start;
            while (zeros_end < integer_end and self.source[zeros_end] == '0') zeros_end += 1;
            try self.report(
                "luce.lex.number",
                .{ .start = start, .end = zeros_end },
                "a decimal integer may not start with a zero; there are no octal literals in Luce, so write {s}",
                .{self.source[zeros_end..integer_end]},
            );
        }
        try self.emit(if (is_float) .float_literal else .int_literal, span);
    }

    /// Scan a `0x`/`0b` literal: the prefix, then digits of the base
    /// with `_` separators between them (docs/BITWISE.md R3, D7).
    /// Always an integer — there are no hex floats — and always
    /// emitted, so the parser has an operand whatever was wrong.
    fn basedNumber(self: *Lexer, base: enum { hex, binary }) Error!void {
        const start = self.offset;
        self.offset += 2; // 0x or 0b
        const digits_start = self.offset;
        while (self.offset < self.source.len) {
            const character = self.source[self.offset];
            const fits = switch (base) {
                .hex => isDigit(character) or
                    (character >= 'a' and character <= 'f') or
                    (character >= 'A' and character <= 'F'),
                .binary => character == '0' or character == '1',
            };
            if (!fits and character != '_') break;
            self.offset += 1;
        }
        const span: Span = .{ .start = start, .end = self.offset };
        if (self.offset == digits_start) {
            // `0x` with nothing after it, or `0xg…` — swallow the
            // glued word so one mistake is one message.
            while (self.offset < self.source.len and isWordPart(self.source[self.offset])) {
                self.offset += 1;
            }
            const whole: Span = .{ .start = start, .end = self.offset };
            try self.report(
                "luce.lex.number",
                whole,
                "a {s} literal needs at least one digit after {s}",
                .{
                    if (base == .hex) "hexadecimal" else "binary",
                    if (base == .hex) "0x" else "0b",
                },
            );
            try self.emit(.int_literal, whole);
            return;
        }
        if (try self.misplacedSeparator(span)) {
            try self.emit(.int_literal, span);
            return;
        }
        // Glued to word characters past the base's digits: `0b12`,
        // `0xFFzz` — one malformed literal.
        if (self.offset < self.source.len and isWordPart(self.source[self.offset])) {
            while (self.offset < self.source.len and isWordPart(self.source[self.offset])) {
                self.offset += 1;
            }
            const whole: Span = .{ .start = start, .end = self.offset };
            try self.report(
                "luce.lex.number",
                whole,
                "malformed numeric literal: a digit does not belong to the base",
                .{},
            );
            try self.emit(.int_literal, whole);
            return;
        }
        try self.emit(.int_literal, span);
    }

    /// Report the first separator that is not between two digits of
    /// its run.  True when one was reported; the literal is still
    /// emitted by the caller, so the parser keeps its operand.
    fn misplacedSeparator(self: *Lexer, span: Span) Error!bool {
        const text = span.slice(self.source);
        for (text, 0..) |character, index| {
            if (character != '_') continue;
            const before_ok = index > 0 and (isDigit(text[index - 1]) or
                isHexDigit(text[index - 1]));
            const after_ok = index + 1 < text.len and (isDigit(text[index + 1]) or
                isHexDigit(text[index + 1]));
            // `0x_` would pass the digit test through `x`; the prefix
            // letters are not digits a separator may touch.
            const after_prefix = index == 2 and text.len > 2 and text[0] == '0' and
                (text[1] == 'x' or text[1] == 'X' or text[1] == 'b' or text[1] == 'B');
            if (before_ok and after_ok and !after_prefix) continue;
            try self.report(
                "luce.lex.number",
                .{ .start = span.start + index, .end = span.start + index + 1 },
                "a digit separator sits between digits: 1_000, 0xFF_FF",
                .{},
            );
            return true;
        }
        return false;
    }

    /// True when a numeric literal was just emitted and ends exactly
    /// here, so the `.` under the cursor is glued to it.
    fn afterNumberLiteral(self: *const Lexer) bool {
        const emitted = self.tokens.items;
        if (emitted.len == 0) return false;
        const last = emitted[emitted.len - 1];
        if (last.kind != .int_literal and last.kind != .float_literal) return false;
        return last.span.end == self.offset;
    }

    /// `1.2.3` — a second decimal point on a number that already has
    /// one.  This used to reach `leadingPointNumber`, which named the
    /// wrong mistake and printed advice that made it worse: "write
    /// 0.3" applied to `1.2.3` yields `1.20.3`.
    ///
    /// Every following `.digits` run is swallowed rather than emitted.
    /// The well-formed number in front is already a token, so the
    /// parser gets the operand it needs and no cascade — and a third
    /// point is part of the same mistake, not a second one.
    fn extraDecimalPoint(self: *Lexer) Error!void {
        const literal_start = self.tokens.items[self.tokens.items.len - 1].span.start;
        const kept: Span = .{ .start = literal_start, .end = self.offset };
        const start = self.offset;
        while (self.offset < self.source.len and self.source[self.offset] == '.' and
            isDigit(self.peek(1)))
        {
            self.offset += 1; // the '.'
            while (self.offset < self.source.len and isDigit(self.source[self.offset])) {
                self.offset += 1;
            }
            self.scanExponent();
        }
        const whole: Span = .{ .start = literal_start, .end = self.offset };
        try self.report(
            "luce.lex.number",
            .{ .start = start, .end = self.offset },
            "a number has one decimal point; {s} was read as {s}",
            .{ whole.slice(self.source), kept.slice(self.source) },
        );
    }

    /// `.5` — a fraction with nothing in front of it.  Report the fix
    /// and emit the float anyway, so the parser sees the operand the
    /// author meant rather than a dot it has no rule for.
    fn leadingPointNumber(self: *Lexer) Error!void {
        const start = self.offset;
        self.offset += 1; // the '.'
        while (self.offset < self.source.len and isDigit(self.source[self.offset])) {
            self.offset += 1;
        }
        self.scanExponent();
        const span: Span = .{ .start = start, .end = self.offset };
        try self.report(
            "luce.lex.number",
            span,
            "a float needs a digit before the point; write 0{s}",
            .{span.slice(self.source)},
        );
        try self.emit(.float_literal, span);
    }

    /// Consume `e`/`E` with an optional sign and at least one digit,
    /// leaving the cursor alone when there is no well-formed exponent.
    fn scanExponent(self: *Lexer) void {
        if (self.offset >= self.source.len) return;
        if (self.source[self.offset] != 'e' and self.source[self.offset] != 'E') return;
        var look = self.offset + 1;
        if (look < self.source.len and (self.source[look] == '+' or self.source[look] == '-')) {
            look += 1;
        }
        if (look >= self.source.len or !isDigit(self.source[look])) return;
        self.offset = look;
        while (self.offset < self.source.len and isDigit(self.source[self.offset])) {
            self.offset += 1;
        }
    }

    // -- strings ----------------------------------------------------------

    /// Scan `"..."`.  A string never crosses a line ending — not even
    /// behind a backslash — so a missing quote costs one line, not the
    /// rest of the file.
    fn string(self: *Lexer) Error!void {
        const start = self.offset;
        self.offset += 1;
        var escaped_quote = false;
        while (self.offset < self.source.len) {
            const character = self.source[self.offset];
            if (character == '"') {
                self.offset += 1;
                try self.emit(.string_literal, .{ .start = start, .end = self.offset });
                return;
            }
            if (character == '\n') break;
            if (character == '\\') {
                self.offset += 1;
                if (self.offset >= self.source.len) break;
                if (self.source[self.offset] == '\n') break;
                switch (self.source[self.offset]) {
                    'n', 't', '\\' => {},
                    '"' => escaped_quote = true,
                    else => try self.report(
                        "luce.lex.escape",
                        .{ .start = self.offset - 1, .end = self.offset + 1 },
                        "unknown escape (use \\n, \\t, \\\\, or \\\")",
                        .{},
                    ),
                }
                self.offset += 1;
                continue;
            }
            try self.checkTextByte(self.offset);
            self.offset += 1;
        }
        const span: Span = .{ .start = start, .end = self.offset };
        // CPython's touch: when the run contains an escaped quote, the
        // likeliest mistake is that the quote meant to close it.
        if (escaped_quote) {
            try self.report(
                "luce.lex.str",
                span,
                "unterminated string; perhaps you escaped the closing quote?",
                .{},
            );
        } else {
            try self.report("luce.lex.str", span, "unterminated string", .{});
        }
        // Recovery: hand the parser a literal anyway.  It slices the
        // quotes off, so this needs the opening quote plus one byte to
        // stay in bounds; a file that ends on a bare `"` gets none.
        if (span.end - span.start >= 2) try self.emit(.string_literal, span);
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
            // An f-string, like a string, lives on one line.
            if (character == '\n') break;
            if (depth == 0) {
                if (character == '"') {
                    self.offset += 1;
                    try self.emit(.fstring, .{ .start = start, .end = self.offset });
                    return;
                }
                if (character == '\\') {
                    // The escape set is the parser's business; here it
                    // only matters that a backslash escapes neither the
                    // end of the line nor the end of the file.
                    if (self.offset + 1 >= self.source.len) break;
                    if (self.source[self.offset + 1] == '\n') break;
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
                try self.checkTextByte(self.offset);
                self.offset += 1;
            } else {
                // Inside a hole: skip nested strings whole, track brace
                // nesting.  The hole is Luce code, and the parser
                // re-lexes it, so its bytes are checked there.
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
        const span: Span = .{ .start = start, .end = self.offset };
        try self.report("luce.lex.str", span, "unterminated f-string", .{});
        // Recovery, as for `str()`: the parser slices off `f"` and
        // the closing quote, so three bytes is the minimum it can hold.
        if (span.end - span.start >= 3) try self.emit(.fstring, span);
    }

    /// Advance past a `"..."` nested inside an f-string hole, honoring
    /// escapes, so its closing quote is not mistaken for the
    /// f-string's.  Stops at the end of input or of the line.
    fn skipNestedString(self: *Lexer) void {
        self.offset += 1; // opening "
        while (self.offset < self.source.len) {
            const character = self.source[self.offset];
            if (character == '\n') return;
            if (character == '\\') {
                if (self.offset + 1 >= self.source.len) {
                    self.offset += 1;
                    return;
                }
                if (self.source[self.offset + 1] == '\n') return;
                self.offset += 2;
                continue;
            }
            self.offset += 1;
            if (character == '"') return;
        }
    }

    /// Scan a single-quoted character spelling. Validation belongs to
    /// the parser because it needs the decoded value: this stage only
    /// finds the matching quote without mistaking `\'` for it. Like a
    /// string, a character never crosses a line ending.
    fn characterLiteral(self: *Lexer) Error!void {
        const start = self.offset;
        self.offset += 1;
        while (self.offset < self.source.len) {
            const character = self.source[self.offset];
            if (character == '\n') break;
            if (character == '\'') {
                self.offset += 1;
                try self.emit(.char_literal, .{ .start = start, .end = self.offset });
                return;
            }
            if (character == '\\') {
                self.offset += 1;
                if (self.offset >= self.source.len or self.source[self.offset] == '\n') break;
                self.offset += 1;
                continue;
            }
            try self.checkTextByte(self.offset);
            self.offset += 1;
        }
        const span: Span = .{ .start = start, .end = self.offset };
        try self.report("luce.lex.char", span, "unterminated character literal", .{});
        if (span.end - span.start >= 2) try self.emit(.char_literal, span);
    }

    // -- rejections -------------------------------------------------------

    /// Report one ASCII character the language has no use for, and step
    /// past it.  A run of the *same* character is one mistake and one
    /// diagnostic (rustc's `swallow_next_invalid`): a file of noise
    /// should read as a file of noise, not as four thousand messages.
    fn unexpectedCharacter(self: *Lexer) Error!void {
        const first = self.source[self.offset];
        const begin = self.offset;
        while (self.offset < self.source.len and self.source[self.offset] == first) {
            self.offset += 1;
        }
        const span: Span = .{ .start = begin, .end = self.offset };
        // `&&` and `||` are one operator to the person who typed them,
        // and the one they mean has a Luce spelling.  Answering them as
        // a repeated stray character is true and unhelpful — the same
        // mistake the parser's foreign-operator pairs make, on the two
        // characters that never became tokens at all.
        if (self.offset - begin == 2) {
            if (doubledOperator(first)) |written| {
                return self.report(
                    "luce.lex.character",
                    span,
                    "there is no '{c}{c}' operator: write '{s}'",
                    .{ first, first, written },
                );
            }
        }
        var count_text: [40]u8 = undefined;
        const repeated: []const u8 = if (self.offset - begin == 1) "" else std.fmt.bufPrint(
            &count_text,
            ", repeated {d} times",
            .{self.offset - begin},
        ) catch "";
        if (first < 0x20 or first == 0x7f) {
            try self.report(
                "luce.lex.character",
                span,
                "unexpected control byte 0x{X:0>2}{s}",
                .{ first, repeated },
            );
        } else if (hintFor(first)) |hint| {
            try self.report(
                "luce.lex.character",
                span,
                "unexpected character '{c}' ({s}){s}",
                .{ first, hint, repeated },
            );
        } else {
            try self.report(
                "luce.lex.character",
                span,
                "unexpected character '{c}'{s}",
                .{ first, repeated },
            );
        }
    }

    /// A non-ASCII character outside a name.  Three kinds turn up in
    /// real files and each gets its own answer: a bidirectional
    /// control, a look-alike that has an ASCII spelling, and a letter
    /// that was meant as part of a name.
    fn foreignCharacter(self: *Lexer) Error!void {
        const at = self.offset;
        if (bidiControlAt(self.source, at)) |codepoint| {
            try self.reportBidi(at, codepoint);
            self.offset += if (codepoint == 0x061C) 2 else 3;
            return;
        }
        const length = codepointLength(self.source, at);
        const sequence = self.source[at..][0..length];
        const codepoint = std.unicode.utf8Decode(sequence) catch {
            // Unreachable on prepared text; costs one branch to keep
            // the scanner total rather than trusting the precondition
            // with a pointer.
            self.offset += 1;
            return;
        };
        // A letter glued to ASCII name characters is a name, not a
        // stray: let `word()` take the whole run and report once.
        if (spellingFor(codepoint) == null and self.foreignRunIsName()) return self.word();
        // A matched pair of typographic quotes is one string somebody
        // typed in a word processor, not two stray characters.
        if (try self.typographicString(at, codepoint)) return;
        self.offset += length;
        if (spellingFor(codepoint)) |spelling| {
            try self.report(
                "luce.lex.character",
                .{ .start = at, .end = self.offset },
                "unexpected character '{s}' (U+{X:0>4}): {s}",
                .{ sequence, codepoint, spelling },
            );
        } else {
            try self.report(
                "luce.lex.character",
                .{ .start = at, .end = self.offset },
                "unexpected character '{s}' (U+{X:0>4}); names are ASCII letters, digits and '_'",
                .{ sequence, codepoint },
            );
        }
    }

    /// `“hello”` — a string literal pasted out of a word processor.
    ///
    /// The two quotes are one mistake with one fix, and reporting each
    /// as a stray character says it twice and names neither as the
    /// pair it is.  So an opening typographic quote looks along the
    /// rest of its line for the partner it opens; finding one, it
    /// reports across the whole literal, steps over it, and emits no
    /// token — the statement is left with a hole, and the parser's
    /// complaint about that hole is suppressed by the same rule that
    /// covers every other dropped character.
    ///
    /// Confined to one line, because that is as far as a string
    /// literal reaches in this language and an unmatched open quote
    /// three hundred lines up should not swallow the file.  Unmatched,
    /// it falls through to the ordinary one-character report.
    fn typographicString(self: *Lexer, at: usize, opening: u21) Error!bool {
        const closing = closingQuoteFor(opening) orelse return false;
        var scan = at + codepointLength(self.source, at);
        while (scan < self.source.len and self.source[scan] != '\n') {
            const length = codepointLength(self.source, scan);
            if (scan + length > self.source.len) break;
            const codepoint = std.unicode.utf8Decode(self.source[scan..][0..length]) catch {
                scan += 1;
                continue;
            };
            if (codepoint == closing) {
                self.offset = scan + length;
                // Both codepoints, because a terminal font may render
                // either of them as an ordinary `"` and then the caret
                // is under something that looks already correct.
                try self.report(
                    "luce.lex.character",
                    .{ .start = at, .end = self.offset },
                    "typographic quotes (U+{X:0>4} and U+{X:0>4}) around a string; text is written \"like this\"",
                    .{ opening, closing },
                );
                return true;
            }
            scan += length;
        }
        return false;
    }

    /// Whether the name-shaped run starting at the cursor contains an
    /// ASCII letter, digit or `_`.  That is what separates `étoile`,
    /// which is a name someone tried to write, from a lone emoji.
    fn foreignRunIsName(self: *const Lexer) bool {
        var scan = self.offset;
        while (scan < self.source.len) {
            if (isWordPart(self.source[scan])) return true;
            scan += namePartLength(self.source, scan) orelse return false;
        }
        return false;
    }
};

fn isDigit(character: u8) bool {
    return character >= '0' and character <= '9';
}

fn isWordStart(character: u8) bool {
    return (character >= 'a' and character <= 'z') or
        (character >= 'A' and character <= 'Z') or character == '_';
}

fn isWordPart(character: u8) bool {
    return isWordStart(character) or isDigit(character);
}

/// The length of the codepoint starting at `at`.  Prepared text is
/// valid UTF-8, so the lead byte is enough; the `catch 1` keeps the
/// scanner advancing if that precondition is ever broken in a build
/// where it is not checked.
fn codepointLength(source: []const u8, at: usize) usize {
    const length = std.unicode.utf8ByteSequenceLength(source[at]) catch return 1;
    return if (at + length <= source.len) length else 1;
}

/// The length of a non-ASCII character that may appear inside a name
/// while recovering, or null when the character at `at` is not one.
///
/// Luce names are ASCII, full stop — this is not a Unicode identifier
/// rule, it is the rule for how far a *mistake* extends.  Everything
/// non-ASCII counts except what plainly belongs to some other part of
/// the language: a bidirectional control, and a look-alike with an
/// ASCII spelling (`é` continues a name; `—` does not).
fn namePartLength(source: []const u8, at: usize) ?usize {
    if (at >= source.len or source[at] < 0x80) return null;
    if (bidiControlAt(source, at) != null) return null;
    const length = codepointLength(source, at);
    const codepoint = std.unicode.utf8Decode(source[at..][0..length]) catch return null;
    if (spellingFor(codepoint) != null) return null;
    return length;
}

/// The bidirectional formatting character starting at `at`, or null.
///
/// These are the Trojan Source characters (CVE-2021-42574): they
/// reorder how a line renders without changing what it means, so a
/// reviewer and a compiler can be shown two different programs.  Every
/// one of them leads with 0xD8 or 0xE2, so scanning for them costs a
/// single comparison per byte.
fn bidiControlAt(source: []const u8, at: usize) ?u21 {
    const first = source[at];
    if (first != 0xD8 and first != 0xE2) return null;
    const length: usize = if (first == 0xD8) 2 else 3;
    if (at + length > source.len) return null;
    const codepoint = std.unicode.utf8Decode(source[at..][0..length]) catch return null;
    return switch (codepoint) {
        0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069 => codepoint,
        else => null,
    };
}

/// The typographic quote that closes this one, for the four pairs a
/// word processor produces.  A straight-looking `"` substitute is not
/// here: `„…”` and the rest of the rarer pairs are not what anyone
/// pastes, and a wrong guess would swallow a line.
fn closingQuoteFor(opening: u21) ?u21 {
    return switch (opening) {
        0x2018 => 0x2019, // ‘ ’
        0x201C => 0x201D, // “ ”
        0x00AB => 0x00BB, // « »
        0x2039 => 0x203A, // ‹ ›
        else => null,
    };
}

/// What to write instead of a non-ASCII character people actually
/// paste into source, or null when there is nothing useful to say.
///
/// Cut down from rustc's confusables table (which comes from
/// unicode.org's `confusables.txt`) to what a Luce file plausibly
/// contains: the quotes an editor curls, the dashes a word processor
/// substitutes, the spaces a web page carries, the operators a
/// mathematician writes, and the fullwidth forms an input method
/// leaves behind.  Doubling as the "is this part of a name" test is
/// deliberate — a character with an ASCII spelling is punctuation
/// someone meant, not a letter.
fn spellingFor(codepoint: u21) ?[]const u8 {
    return switch (codepoint) {
        0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => "a Unicode space; write an ordinary space",
        0x00AD, 0x034F, 0x200B...0x200D, 0x2060...0x2064, 0xFEFF => "an invisible character; delete it",
        0x00AB, 0x00BB, 0x2018...0x201F => "a typographic quote; text is written \"like this\"",
        0x2010...0x2015, 0x2212 => "write '-'",
        0x00D7 => "write '*'",
        0x00F7, 0x2215 => "write '/'",
        0x2260 => "write '!='",
        0x2264 => "write '<='",
        0x2265 => "write '>='",
        0x2192, 0x21D2, 0x27F6 => "write '->'",
        0xFF08 => "write '('",
        0xFF09 => "write ')'",
        0xFF0B => "write '+'",
        0xFF0C, 0x3001 => "write ','",
        0xFF1A => "write ':'",
        0xFF1D => "write '='",
        0x3002 => "write '.'",
        else => null,
    };
}

/// Why a digit run followed by identifier characters is not a number.
/// The reason is the whole value of the diagnostic: `0xFF` and `12ab`
/// are different mistakes with different fixes.
fn numberProblem(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '0') {
        switch (text[1]) {
            // Hex and binary are in the language now (docs/BITWISE.md
            // R3) and never reach here; octal keeps its refusal.
            'o', 'O' => return "octal literals are not in the language; write the value in decimal or hexadecimal",
            else => {},
        }
    }
    const last = text[text.len - 1];
    if (last == 'e' or last == 'E') return "an exponent needs at least one digit";
    return "a number cannot be followed by letters";
}

fn isHexDigit(character: u8) bool {
    return isDigit(character) or
        (character >= 'a' and character <= 'f') or
        (character >= 'A' and character <= 'F');
}

/// A short "here is the Luce way" note for the punctuation people
/// reach for out of habit.  Null when there is nothing useful to add.
/// The Luce keyword a doubled stray character was reaching for.  Only
/// the two logical operators: `&&` and `||` are written by everyone
/// arriving from C, and a doubled `^` or `~` is not an operator
/// anywhere and stays a repeated stray.
fn doubledOperator(character: u8) ?[]const u8 {
    // `&` and `|` were here while they were strays; they are operators
    // now (docs/BITWISE.md), and `&&`/`||` fail in the parser with the
    // second character as an ordinary unexpected token.
    _ = character;
    return null;
}

fn hintFor(character: u8) ?[]const u8 {
    return switch (character) {
        '!' => "use 'not'; '!=' is inequality",
        ';' => "a statement ends at the line, not at a ';'",
        '\\' => "a backslash only escapes inside a string",
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn lexKinds(allocator: Allocator, text: []const u8, expected: []const Kind) !void {
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tokens = (try lex(allocator, text, &diagnostics)).tokens;
    defer allocator.free(tokens);
    try testing.expectEqual(@as(usize, 0), diagnostics.count());
    var kinds: std.ArrayList(Kind) = .empty;
    defer kinds.deinit(allocator);
    for (tokens) |item| try kinds.append(allocator, item.kind);
    try testing.expectEqualSlices(Kind, expected, kinds.items);
}

/// Lex `text` and assert the kinds *and* that each listed diagnostic
/// code appears, in order, with nothing else reported.
fn lexWithDiagnostics(
    allocator: Allocator,
    text: []const u8,
    expected: []const Kind,
    codes: []const []const u8,
) !void {
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tokens = (try lex(allocator, text, &diagnostics)).tokens;
    defer allocator.free(tokens);
    var kinds: std.ArrayList(Kind) = .empty;
    defer kinds.deinit(allocator);
    for (tokens) |item| try kinds.append(allocator, item.kind);
    try testing.expectEqualSlices(Kind, expected, kinds.items);
    try testing.expectEqual(codes.len, diagnostics.count());
    for (codes, 0..) |code, index| {
        try testing.expectEqualStrings(code, diagnostics.at(index).?.code);
    }
}

test "lexer produces layout tokens for indented blocks" {
    try lexKinds(testing.allocator,
        \\func blend(first: Point, second: Point):
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
    const tokens = (try lex(allocator, "\tlet a = \"open\n  bad = 1\n", &diagnostics)).tokens;
    defer allocator.free(tokens);
    try testing.expect(diagnostics.count() >= 2);
}

test "every keyword lexes as itself, and a word containing one does not" {
    const allocator = testing.allocator;
    for (token_mod.keywords) |keyword| {
        try lexKinds(allocator, keyword.word, &.{ keyword.kind, .newline, .end_of_file });
        var text: [64]u8 = undefined;
        const glued = try std.fmt.bufPrint(&text, "{s}_x", .{keyword.word});
        try lexKinds(allocator, glued, &.{ .identifier, .newline, .end_of_file });
    }
}

test "a name starts with a letter, and only the lone underscore passes" {
    const allocator = testing.allocator;
    // A leading underscore is refused by name, everywhere a word can
    // stand — declarations and uses alike — and the token is still
    // emitted so the parser sees the line the author wrote
    // [VISIBILITY.md R3].
    try lexWithDiagnostics(
        allocator,
        "let _total = 1\n",
        &.{ .keyword_let, .identifier, .assign, .int_literal, .newline, .end_of_file },
        &.{"luce.lex.name"},
    );
    try lexWithDiagnostics(
        allocator,
        "a = _x + __\n",
        &.{ .identifier, .assign, .identifier, .plus, .identifier, .newline, .end_of_file },
        &.{ "luce.lex.name", "luce.lex.name" },
    );
    // The lone `_` is the array-shape wildcard, not a name, and lexes
    // clean; interior and trailing underscores are the house style.
    try lexKinds(allocator, "array[i64, _]\n", &.{
        .identifier, .left_bracket, .identifier, .comma, .identifier, .right_bracket,
        .newline,    .end_of_file,
    });
    try lexKinds(allocator, "word_end_ = fold_case\n", &.{
        .identifier, .assign, .identifier, .newline, .end_of_file,
    });
}

// --- numbers ---------------------------------------------------------------

test "every decimal literal shape lexes, and only a fraction makes a float" {
    try lexKinds(testing.allocator, "a = 0\n", &.{ .identifier, .assign, .int_literal, .newline, .end_of_file });
    try lexKinds(testing.allocator, "a = 1.5\n", &.{ .identifier, .assign, .float_literal, .newline, .end_of_file });
    try lexKinds(testing.allocator, "a = 1e10\n", &.{ .identifier, .assign, .float_literal, .newline, .end_of_file });
    try lexKinds(testing.allocator, "a = 1E+10\n", &.{ .identifier, .assign, .float_literal, .newline, .end_of_file });
    try lexKinds(testing.allocator, "a = 1.5e-3\n", &.{ .identifier, .assign, .float_literal, .newline, .end_of_file });
    // A dot with no digit after it is a dot, not a fraction.
    try lexKinds(testing.allocator, "a = 1.b\n", &.{
        .identifier, .assign, .int_literal, .dot, .identifier, .newline, .end_of_file,
    });
}

test "hex, binary, and separated literals lex clean; octal stays refused by name" {
    const allocator = testing.allocator;
    // The three R3 brought in (docs/BITWISE.md).
    const legal = [_][]const u8{ "0xFF", "0b1010", "1_000", "0xFF_FF", "0b1010_1010", "0Xff", "0B01" };
    for (legal) |shape| {
        var text: [32]u8 = undefined;
        const source = try std.fmt.bufPrint(&text, "a = {s}\n", .{shape});
        try lexKinds(allocator, source, &.{
            .identifier, .assign, .int_literal, .newline, .end_of_file,
        });
    }
    // Octal keeps its refusal, and an unfinished exponent its own.
    const refused = [_][]const u8{ "0o17", "1e" };
    for (refused) |shape| {
        var text: [32]u8 = undefined;
        const source = try std.fmt.bufPrint(&text, "a = {s}\n", .{shape});
        try lexWithDiagnostics(
            allocator,
            source,
            &.{ .identifier, .assign, .int_literal, .newline, .end_of_file },
            &.{"luce.lex.number"},
        );
    }
    // A misplaced separator names its rule, at the separator.
    const misplaced = [_][]const u8{ "1__0", "1_", "0x_FF", "1_.5" };
    for (misplaced) |shape| {
        var text: [32]u8 = undefined;
        const source = try std.fmt.bufPrint(&text, "a = {s}\n", .{shape});
        var diagnostics = Diagnostics.init(allocator);
        defer diagnostics.deinit();
        const tokens = (try lex(allocator, source, &diagnostics)).tokens;
        defer allocator.free(tokens);
        try testing.expect(diagnostics.count() >= 1);
        try testing.expectEqualStrings("luce.lex.number", diagnostics.at(0).?.code);
    }
    // An empty base names what it needs.
    try lexWithDiagnostics(
        allocator,
        "a = 0x\n",
        &.{ .identifier, .assign, .int_literal, .newline, .end_of_file },
        &.{"luce.lex.number"},
    );
}

test "a malformed literal names the reason it is malformed" {
    try testing.expectEqualStrings(
        "octal literals are not in the language; write the value in decimal or hexadecimal",
        numberProblem("0o17"),
    );
    try testing.expectEqualStrings("an exponent needs at least one digit", numberProblem("1e"));
    try testing.expectEqualStrings("a number cannot be followed by letters", numberProblem("12ab"));
}

test "a leading zero in a decimal integer is refused, and only there" {
    // `0755` is 493 in C and 755 here; the gap between those is the
    // whole reason for the rule.
    for ([_][]const u8{ "007", "00", "0755" }) |shape| {
        var text: [32]u8 = undefined;
        const source = try std.fmt.bufPrint(&text, "a = {s}\n", .{shape});
        try lexWithDiagnostics(
            testing.allocator,
            source,
            &.{ .identifier, .assign, .int_literal, .newline, .end_of_file },
            &.{"luce.lex.number"},
        );
    }
    // Zero itself, and a zero that is only the start of a float, are
    // exactly what people write.
    try lexKinds(testing.allocator, "a = 0\n", &.{ .identifier, .assign, .int_literal, .newline, .end_of_file });
    try lexKinds(testing.allocator, "a = 0.5\n", &.{ .identifier, .assign, .float_literal, .newline, .end_of_file });
    try lexKinds(testing.allocator, "a = 0e1\n", &.{ .identifier, .assign, .float_literal, .newline, .end_of_file });
    // A base prefix is not a leading zero: `0xFF` is a legal literal
    // (docs/BITWISE.md R3) and lexes clean.
    try lexKinds(testing.allocator, "a = 0xFF\n", &.{
        .identifier, .assign, .int_literal, .newline, .end_of_file,
    });
}

test "a fraction with no integer part names the fix and still yields an operand" {
    try lexWithDiagnostics(
        testing.allocator,
        "a = .5\n",
        &.{ .identifier, .assign, .float_literal, .newline, .end_of_file },
        &.{"luce.lex.number"},
    );
    const allocator = testing.allocator;
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tokens = (try lex(allocator, "a = .5e2\n", &diagnostics)).tokens;
    defer allocator.free(tokens);
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "write 0.5e2") != null);
    // Member access is untouched: a dot before a *name* is a dot.
    try lexKinds(testing.allocator, "a = b.c\n", &.{
        .identifier, .assign, .identifier, .dot, .identifier, .newline, .end_of_file,
    });
}

test "a malformed float keeps its well-formed prefix as the operand" {
    try lexWithDiagnostics(
        testing.allocator,
        "a = 1.5abc\n",
        &.{ .identifier, .assign, .float_literal, .newline, .end_of_file },
        &.{"luce.lex.number"},
    );
}

test "a second decimal point is one diagnostic and no second operand" {
    // `1.2.3` reached the `.5` handler, which named the wrong mistake
    // and advised an edit that made it worse: "write 0.3" applied here
    // yields `1.20.3`.  The extra run is swallowed, so the parser sees
    // one operand and there is no cascade.
    try lexWithDiagnostics(
        testing.allocator,
        "a = 1.2.3\n",
        &.{ .identifier, .assign, .float_literal, .newline, .end_of_file },
        &.{"luce.lex.number"},
    );
    // A third point is the same mistake, not a second one.
    try lexWithDiagnostics(
        testing.allocator,
        "a = 1.2.3.4\n",
        &.{ .identifier, .assign, .float_literal, .newline, .end_of_file },
        &.{"luce.lex.number"},
    );
}

test "a point with no fraction is a number, not an unfinished member access" {
    try lexWithDiagnostics(
        testing.allocator,
        "a = 1.\n",
        &.{ .identifier, .assign, .float_literal, .newline, .end_of_file },
        &.{"luce.lex.number"},
    );
    // A name after the point really is member access, and stays one.
    try lexKinds(testing.allocator, "a = 5.foo\n", &.{
        .identifier, .assign, .int_literal, .dot, .identifier, .newline, .end_of_file,
    });
}

// --- strings ---------------------------------------------------------------

test "the four escapes are accepted and every other one is reported" {
    try lexKinds(testing.allocator, "a = \"\\n\\t\\\\\\\"\"\n", &.{
        .identifier, .assign, .string_literal, .newline, .end_of_file,
    });
    for ([_][]const u8{ "\\r", "\\0", "\\x41", "\\u{41}", "\\q" }) |escape| {
        var text: [32]u8 = undefined;
        const source = try std.fmt.bufPrint(&text, "a = \"{s}\"\n", .{escape});
        var diagnostics = Diagnostics.init(testing.allocator);
        defer diagnostics.deinit();
        const tokens = (try lex(testing.allocator, source, &diagnostics)).tokens;
        defer testing.allocator.free(tokens);
        try testing.expect(diagnostics.count() >= 1);
        try testing.expectEqualStrings("luce.lex.escape", diagnostics.at(0).?.code);
    }
}

test "a string never crosses a line, not even behind a backslash" {
    // The trailing backslash must not swallow the newline and let the
    // literal run on into the next line's quote.
    try lexWithDiagnostics(
        testing.allocator,
        "a = \"one\\\nb = \"two\"\n",
        &.{
            .identifier,  .assign, .string_literal, .newline,
            .identifier,  .assign, .string_literal, .newline,
            .end_of_file,
        },
        &.{"luce.lex.str"},
    );
}

test "an unterminated string reports once and still yields an operand" {
    try lexWithDiagnostics(
        testing.allocator,
        "a = \"open\nb = 1\n",
        &.{
            .identifier, .assign,      .string_literal, .newline,     .identifier,
            .assign,     .int_literal, .newline,        .end_of_file,
        },
        &.{"luce.lex.str"},
    );
}

test "a lone opening quote at end of input yields no unsliceable token" {
    const allocator = testing.allocator;
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tokens = (try lex(allocator, "a = \"", &diagnostics)).tokens;
    defer allocator.free(tokens);
    for (tokens) |item| {
        if (item.kind == .string_literal) try testing.expect(item.span.end - item.span.start >= 2);
        if (item.kind == .fstring) try testing.expect(item.span.end - item.span.start >= 3);
    }
    try testing.expectEqual(@as(usize, 1), diagnostics.count());
}

test "f-strings scan holes, nested strings, and doubled braces whole" {
    try lexKinds(testing.allocator, "a = f\"x{m[\"k\"]}y{{z}}\"\n", &.{
        .identifier, .assign, .fstring, .newline, .end_of_file,
    });
}

test "an unterminated f-string stops at the line and still yields an operand" {
    try lexWithDiagnostics(
        testing.allocator,
        "a = f\"x{y\nb = 1\n",
        &.{
            .identifier, .assign,      .fstring, .newline,     .identifier,
            .assign,     .int_literal, .newline, .end_of_file,
        },
        &.{"luce.lex.str"},
    );
}

// --- layout ----------------------------------------------------------------

test "a backslash at the very end of input cannot run a span past the source" {
    const allocator = testing.allocator;
    for ([_][]const u8{ "a = f\"x\\", "a = f\"{\"y\\", "a = \"x\\" }) |source| {
        var diagnostics = Diagnostics.init(allocator);
        defer diagnostics.deinit();
        const tokens = (try lex(allocator, source, &diagnostics)).tokens;
        defer allocator.free(tokens);
        for (tokens) |item| try testing.expect(item.span.end <= source.len);
        for (0..diagnostics.count()) |index| {
            try testing.expect(diagnostics.at(index).?.span.end <= source.len);
        }
    }
}

test "a Windows file lexes exactly like a Unix one, because stage 1 prepared it" {
    // The lexer has no CRLF path at all; this proves it needs none.
    const allocator = testing.allocator;
    for ([_][2][]const u8{
        .{ "func f():\n    a = 1\n\n    b = 2\n", "func f():\r\n    a = 1\r\n\r\n    b = 2\r\n" },
        .{
            "func f():\n    a = 1\n    # note\n    b = 2\n",
            "func f():\r\n    a = 1\r\n    # note\r\n    b = 2\r\n",
        },
    }) |pair| {
        const prepared_crlf = switch (try source_mod.prepare(allocator, pair[1])) {
            .text => |text| text,
            .problem => return error.TestUnexpectedResult,
        };
        defer allocator.free(prepared_crlf);
        try testing.expectEqualStrings(pair[0], prepared_crlf);

        var with_lf = Diagnostics.init(allocator);
        defer with_lf.deinit();
        const lf = (try lex(allocator, pair[0], &with_lf)).tokens;
        defer allocator.free(lf);

        var with_crlf = Diagnostics.init(allocator);
        defer with_crlf.deinit();
        const crlf = (try lex(allocator, prepared_crlf, &with_crlf)).tokens;
        defer allocator.free(crlf);

        try testing.expectEqual(@as(usize, 0), with_lf.count());
        try testing.expectEqual(@as(usize, 0), with_crlf.count());
        try testing.expectEqual(lf.len, crlf.len);
        for (lf, crlf) |left, right| try testing.expectEqual(left.kind, right.kind);
    }
}

test "isPrepared states the precondition stage 1 guarantees" {
    try testing.expect(isPrepared("func main():\n    return\n"));
    try testing.expect(isPrepared(""));
    try testing.expect(isPrepared("# h\u{00E9}llo \u{2014} ok\n"));
    // Everything stage 1 refuses or folds.
    try testing.expect(!isPrepared("a\r\nb"));
    try testing.expect(!isPrepared("a\rb"));
    try testing.expect(!isPrepared("a\x00b"));
    try testing.expect(!isPrepared("\xEF\xBB\xBFa"));
    try testing.expect(!isPrepared("a\xff\xfe"));
    try testing.expect(!isPrepared("x\xE2\x82")); // truncated sequence
}

test "a tab-indented file reports once per line and keeps its block structure" {
    try lexWithDiagnostics(
        testing.allocator,
        "func f():\n\t\ta = 1\n\t\tb = 2\n",
        &.{
            .keyword_func, .identifier,  .left_paren, .right_paren, .colon,
            .newline,      .indent,      .identifier, .assign,      .int_literal,
            .newline,      .identifier,  .assign,     .int_literal, .newline,
            .dedent,       .end_of_file,
        },
        &.{ "luce.lex.tab", "luce.lex.tab" },
    );
}

test "a dedent to a column that never opened reports and lands on the nearest" {
    // Two mistakes here, and each is named: an eight-column step in,
    // then a landing on a column no block ever opened.
    try lexWithDiagnostics(
        testing.allocator,
        "func f():\n        a = 1\n    b = 2\n",
        &.{
            .keyword_func, .identifier,  .left_paren, .right_paren, .colon,
            .newline,      .indent,      .identifier, .assign,      .int_literal,
            .newline,      .dedent,      .identifier, .assign,      .int_literal,
            .newline,      .end_of_file,
        },
        &.{ "luce.lex.indent", "luce.lex.indent" },
    );
}

test "a file that never dedents still closes every block at end of input" {
    try lexKinds(testing.allocator, "func f():\n    if a:\n        b = 1", &.{
        .keyword_func, .identifier, .left_paren, .right_paren, .colon,
        .newline,      .indent,     .keyword_if, .identifier,  .colon,
        .newline,      .indent,     .identifier, .assign,      .int_literal,
        .newline,      .dedent,     .dedent,     .end_of_file,
    });
}

test "indentation inside brackets is plain spacing" {
    try lexKinds(testing.allocator, "a = [\n        1,\n  2,\n]\n", &.{
        .identifier,  .assign, .left_bracket,  .int_literal, .comma,
        .int_literal, .comma,  .right_bracket, .newline,     .end_of_file,
    });
}

test "map braces suspend layout and remain separate from f-string braces" {
    try lexKinds(testing.allocator,
        \\const names = {
        \\        "one": 1,
        \\  "two": f"{2}",
        \\}
    , &.{
        .keyword_const,  .identifier, .assign,      .left_brace,
        .string_literal, .colon,      .int_literal, .comma,
        .string_literal, .colon,      .fstring,     .comma,
        .right_brace,    .newline,    .end_of_file,
    });
}

test "empty and whitespace-only inputs produce just end of file" {
    try lexKinds(testing.allocator, "", &.{.end_of_file});
    try lexKinds(testing.allocator, "\n\n\n", &.{.end_of_file});
    try lexKinds(testing.allocator, "    ", &.{.end_of_file});
    try lexKinds(testing.allocator, "# only a comment", &.{.end_of_file});
}

// --- rejections ------------------------------------------------------------

test "a non-ASCII character is one diagnostic per codepoint, not per byte" {
    try lexWithDiagnostics(
        testing.allocator,
        "let café = 1\n",
        &.{ .keyword_let, .identifier, .assign, .int_literal, .newline, .end_of_file },
        &.{"luce.lex.character"},
    );
    const allocator = testing.allocator;
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tokens = (try lex(allocator, "a = \u{1F600}\n", &diagnostics)).tokens;
    defer allocator.free(tokens);
    try testing.expectEqual(@as(usize, 1), diagnostics.count());
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "\u{1F600}") != null);
}

test "single quotes produce one character-literal token" {
    for ([_][]const u8{ "a = '('\n", "a = '🙂'\n", "a = '\\n'\n", "a = '\\u{1F44B}'\n" }) |source| {
        try lexKinds(
            testing.allocator,
            source,
            &.{ .identifier, .assign, .char_literal, .newline, .end_of_file },
        );
    }
    // Cardinality is a parser concern because it requires decoding;
    // the lexer still keeps each malformed spelling in one token.
    for ([_][]const u8{ "a = 'hello'\n", "a = ''\n" }) |source| {
        try lexKinds(
            testing.allocator,
            source,
            &.{ .identifier, .assign, .char_literal, .newline, .end_of_file },
        );
    }
}

test "an unterminated character literal stops at the line" {
    try lexWithDiagnostics(
        testing.allocator,
        "a = 'x + \"b\"\n",
        &.{ .identifier, .assign, .char_literal, .newline, .end_of_file },
        &.{"luce.lex.char"},
    );
}

test "habitual punctuation gets a hint toward the Luce spelling" {
    const allocator = testing.allocator;
    for ([_][]const u8{"a = 1;\n"}) |source| {
        var diagnostics = Diagnostics.init(allocator);
        defer diagnostics.deinit();
        const tokens = (try lex(allocator, source, &diagnostics)).tokens;
        defer allocator.free(tokens);
        try testing.expect(diagnostics.count() >= 1);
        try testing.expectEqualStrings("luce.lex.character", diagnostics.at(0).?.code);
        try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "(") != null);
    }
}

test "several malformed constructs on one line each get their own diagnostic" {
    const allocator = testing.allocator;
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tokens = (try lex(allocator, "a = 0o17 ; \"open\nb = 1__0 $ 2\nc = 3\n", &diagnostics)).tokens;
    defer allocator.free(tokens);
    var codes: [8][]const u8 = undefined;
    var found: usize = 0;
    for (0..diagnostics.count()) |index| {
        if (found < codes.len) {
            codes[found] = diagnostics.at(index).?.code;
            found += 1;
        }
    }
    try testing.expectEqual(@as(usize, 5), found);
    try testing.expectEqualStrings("luce.lex.number", codes[0]);
    try testing.expectEqualStrings("luce.lex.character", codes[1]);
    try testing.expectEqualStrings("luce.lex.str", codes[2]);
    try testing.expectEqualStrings("luce.lex.number", codes[3]);
    try testing.expectEqualStrings("luce.lex.character", codes[4]);
    // The last, well-formed line still lexes.
    try testing.expectEqual(Kind.end_of_file, tokens[tokens.len - 1].kind);
}

test "a run of one stray character is one mistake, not four thousand" {
    const allocator = testing.allocator;
    var noise: [4096]u8 = undefined;
    @memset(&noise, '$');
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tokens = (try lex(allocator, &noise, &diagnostics)).tokens;
    defer allocator.free(tokens);
    try testing.expectEqual(@as(usize, 1), diagnostics.count());
    try testing.expect(std.mem.indexOf(u8, diagnostics.at(0).?.message, "4096 times") != null);
    try testing.expectEqual(Kind.end_of_file, tokens[tokens.len - 1].kind);
}

test "reporting is capped so a file of noise cannot flood the diagnostics" {
    const allocator = testing.allocator;
    // Alternating characters defeat run-coalescing, so this is the
    // shape the cap actually has to hold.
    var noise: [4096]u8 = undefined;
    for (&noise, 0..) |*byte, index| byte.* = if (index % 2 == 0) '$' else '`';
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tokens = (try lex(allocator, &noise, &diagnostics)).tokens;
    defer allocator.free(tokens);
    try testing.expectEqual(max_diagnostics + 1, diagnostics.count());
    try testing.expectEqualStrings("luce.lex.limit", diagnostics.at(max_diagnostics).?.code);
    // Lexing itself continued: the stream is still complete.
    try testing.expectEqual(Kind.end_of_file, tokens[tokens.len - 1].kind);
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
    const tokens = (try lex(allocator, prepareInPlace(&noise), &diagnostics)).tokens;
    defer allocator.free(tokens);
    try testing.expect(tokens.len >= 1);
    try testing.expectEqual(Kind.end_of_file, tokens[tokens.len - 1].kind);
}

test "pathological inputs stay linear and terminate" {
    const allocator = testing.allocator;
    // One very long line, deep bracket nesting, and a staircase of
    // ever-deeper indentation: each is a shape that a naive scanner
    // or an unbounded indent stack turns quadratic.
    var long_line: std.ArrayList(u8) = .empty;
    defer long_line.deinit(allocator);
    try long_line.appendNTimes(allocator, 'a', 200_000);
    var brackets: std.ArrayList(u8) = .empty;
    defer brackets.deinit(allocator);
    try brackets.appendNTimes(allocator, '(', 50_000);
    var staircase: std.ArrayList(u8) = .empty;
    defer staircase.deinit(allocator);
    for (0..2_000) |line| {
        try staircase.appendNTimes(allocator, ' ', line);
        try staircase.appendSlice(allocator, "a\n");
    }
    for ([_][]const u8{ long_line.items, brackets.items, staircase.items }) |source| {
        var diagnostics = Diagnostics.init(allocator);
        defer diagnostics.deinit();
        const tokens = (try lex(allocator, source, &diagnostics)).tokens;
        defer allocator.free(tokens);
        try testing.expectEqual(Kind.end_of_file, tokens[tokens.len - 1].kind);
        // At most one token per input byte, plus the closing layout.
        try testing.expect(tokens.len <= source.len + 3);
    }
}

// --- the four-space step ----------------------------------------------------

test "a block is exactly four columns deeper, and anything else is named" {
    // A consistent two-space file is *structurally* fine, so it keeps
    // its blocks; it is still one diagnostic per block that opens.
    try lexWithDiagnostics(
        testing.allocator,
        "func f():\n  a = 1\n  b = 2\n",
        &.{
            .keyword_func, .identifier,  .left_paren, .right_paren, .colon,
            .newline,      .indent,      .identifier, .assign,      .int_literal,
            .newline,      .identifier,  .assign,     .int_literal, .newline,
            .dedent,       .end_of_file,
        },
        &.{"luce.lex.indent"},
    );
    // Eight is as wrong as two.
    try lexWithDiagnostics(
        testing.allocator,
        "func f():\n        a = 1\n",
        &.{
            .keyword_func, .identifier, .left_paren,  .right_paren, .colon,
            .newline,      .indent,     .identifier,  .assign,      .int_literal,
            .newline,      .dedent,     .end_of_file,
        },
        &.{"luce.lex.indent"},
    );
    // Four, at every depth, is silent.
    try lexKinds(testing.allocator, "func f():\n    if a:\n        b = 1\n", &.{
        .keyword_func, .identifier, .left_paren, .right_paren, .colon,
        .newline,      .indent,     .keyword_if, .identifier,  .colon,
        .newline,      .indent,     .identifier, .assign,      .int_literal,
        .newline,      .dedent,     .dedent,     .end_of_file,
    });
}

test "a tab explains its own column, so the step is not reported twice" {
    // `\t\t` is eight columns and would otherwise draw a second
    // diagnostic on top of the one that matters.
    try lexWithDiagnostics(
        testing.allocator,
        "func f():\n\t\ta = 1\n",
        &.{
            .keyword_func, .identifier, .left_paren,  .right_paren, .colon,
            .newline,      .indent,     .identifier,  .assign,      .int_literal,
            .newline,      .dedent,     .end_of_file,
        },
        &.{"luce.lex.tab"},
    );
}

test "nesting is bounded, and the token stream stays balanced past the bound" {
    const allocator = testing.allocator;
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(allocator);
    for (0..max_indent_depth + 20) |level| {
        try deep.appendNTimes(allocator, ' ', level * indent_step);
        try deep.appendSlice(allocator, "if a:\n");
    }
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const lexed = try lex(allocator, deep.items, &diagnostics);
    const tokens = lexed.tokens;
    defer allocator.free(tokens);
    // One bound, one message: the guard used to fire once per line
    // past it, twenty times over for this input.
    try testing.expectEqual(@as(usize, 1), diagnostics.count());
    try testing.expectEqualStrings("luce.lex.indent", diagnostics.at(0).?.code);
    // And the next stage is told, so it adds nothing about a tail this
    // stage wrote itself.
    try testing.expect(lexed.truncated);
    var depth: usize = 0;
    var deepest: usize = 0;
    for (tokens) |item| switch (item.kind) {
        .indent => {
            depth += 1;
            deepest = @max(deepest, depth);
        },
        .dedent => depth -= 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 0), depth);
    try testing.expect(deepest < max_indent_depth);
}

// --- comments ---------------------------------------------------------------

test "a shebang line is an ordinary comment" {
    try lexKinds(testing.allocator, "#!/usr/bin/env loom\nfunc main():\n    return\n", &.{
        .keyword_func, .identifier, .left_paren,     .right_paren, .colon,
        .newline,      .indent,     .keyword_return, .newline,     .dedent,
        .end_of_file,
    });
}

test "a block comment is named, not mis-lexed as arithmetic" {
    // A block comment is skipped to its terminator, so the prose
    // inside costs one message and not one per line.
    try lexWithDiagnostics(
        testing.allocator,
        "a = /* one\n   two */ 1\n",
        &.{ .identifier, .assign, .int_literal, .newline, .end_of_file },
        &.{"luce.lex.comment"},
    );
    // An unterminated one takes the rest of the file, still once.
    try lexWithDiagnostics(
        testing.allocator,
        "a = /* one\n",
        &.{ .identifier, .assign, .newline, .end_of_file },
        &.{"luce.lex.comment"},
    );
    // Division still divides, and `//` is now the operator beside it
    // rather than a diagnostic (docs/NUMERICS.md).
    try lexKinds(testing.allocator, "a = 6 / 2\nb /= 2\n", &.{
        .identifier,  .assign,     .int_literal,  .slash,       .int_literal,
        .newline,     .identifier, .slash_assign, .int_literal, .newline,
        .end_of_file,
    });
    try lexKinds(testing.allocator, "a = 7 // 2\nb //= 2\n", &.{
        .identifier,  .assign,     .int_literal,        .slash_slash, .int_literal,
        .newline,     .identifier, .slash_slash_assign, .int_literal, .newline,
        .end_of_file,
    });
}

// --- text that renders differently from how it runs -------------------------

test "a bidirectional control is refused wherever it hides" {
    const allocator = testing.allocator;
    // In code, in a string, and in a comment: the Trojan Source
    // positions.  U+202E is RIGHT-TO-LEFT OVERRIDE.
    for ([_][]const u8{
        "a = \u{202E}1\n",
        "a = \"x\u{202E}y\"\n",
        "# note \u{202E} here\n",
        "a = f\"x\u{2066}y\"\n",
    }) |source| {
        var diagnostics = Diagnostics.init(allocator);
        defer diagnostics.deinit();
        const tokens = (try lex(allocator, source, &diagnostics)).tokens;
        defer allocator.free(tokens);
        try testing.expectEqual(@as(usize, 1), diagnostics.count());
        try testing.expectEqualStrings("luce.lex.bidi", diagnostics.at(0).?.code);
    }
}

test "a raw control byte inside a string is reported, not carried into the text" {
    try lexWithDiagnostics(
        testing.allocator,
        "a = \"x\x1by\"\n",
        &.{ .identifier, .assign, .string_literal, .newline, .end_of_file },
        &.{"luce.lex.character"},
    );
    // A tab is a tab wherever it is; `\t` is how text spells one.
    try lexWithDiagnostics(
        testing.allocator,
        "a = \"x\ty\"\n",
        &.{ .identifier, .assign, .string_literal, .newline, .end_of_file },
        &.{"luce.lex.tab"},
    );
}

test "a look-alike character is named with the ASCII to write instead" {
    const allocator = testing.allocator;
    const cases = [_]struct { source: []const u8, wanted: []const u8 }{
        .{ .source = "a = \u{201C}x\u{201D}\n", .wanted = "\"like this\"" },
        .{ .source = "a\u{00A0}= 1\n", .wanted = "ordinary space" },
        .{ .source = "a = 1 \u{2260} 2\n", .wanted = "'!='" },
        .{ .source = "a = 1 \u{2014} 2\n", .wanted = "'-'" },
        .{ .source = "a\u{FEFF} = 1\n", .wanted = "invisible" },
        .{ .source = "func f()\u{FF1A}\n    return\n", .wanted = "':'" },
    };
    for (cases) |case| {
        var diagnostics = Diagnostics.init(allocator);
        defer diagnostics.deinit();
        const tokens = (try lex(allocator, case.source, &diagnostics)).tokens;
        defer allocator.free(tokens);
        try testing.expect(diagnostics.count() >= 1);
        const message = diagnostics.at(0).?.message;
        try testing.expectEqualStrings("luce.lex.character", diagnostics.at(0).?.code);
        try testing.expect(std.mem.indexOf(u8, message, case.wanted) != null);
        try testing.expect(std.mem.indexOf(u8, message, "U+") != null);
    }
}

test "a name with a foreign letter in it stays one name" {
    // `caf\u{00E9}` is a name someone tried to write; splitting it into
    // `caf`, an error, and nothing else would cost a second diagnostic
    // from the parser for a mistake it cannot help with.
    try lexWithDiagnostics(
        testing.allocator,
        "let caf\u{00E9} = 1\n",
        &.{ .keyword_let, .identifier, .assign, .int_literal, .newline, .end_of_file },
        &.{"luce.lex.character"},
    );
    try lexWithDiagnostics(
        testing.allocator,
        "let \u{00E9}toile = 1\n",
        &.{ .keyword_let, .identifier, .assign, .int_literal, .newline, .end_of_file },
        &.{"luce.lex.character"},
    );
    // A character that is nobody's letter stays a stray character.
    try lexWithDiagnostics(
        testing.allocator,
        "a = \u{1F600}\n",
        &.{ .identifier, .assign, .newline, .end_of_file },
        &.{"luce.lex.character"},
    );
}

// ---------------------------------------------------------------------------
// Property fuzzing
// ---------------------------------------------------------------------------
//
// Zig's own tokenizer fuzzes exactly this way: on Smith-generated
// input, assert the *invariants* rather than a fixed token list.  Two
// targets, because they find different bugs — random bytes reach the
// error paths, and random *fragments* reach the states a scanner only
// gets into after several correct decisions in a row (a hole inside an
// f-string inside a bracket inside a block).  Under `zig build test`
// each runs its corpus; `zig build test --fuzz` explores from there.
//
// Both feed the lexer *prepared* text, because that is its
// precondition and therefore the only input worth proving anything
// about — fuzzing bytes stage 1 rejects would be fuzzing dead code.

/// Force a byte buffer to satisfy `isPrepared`, in place, changing as
/// little as possible: this is the fuzzer's stand-in for stage 1.
fn prepareInPlace(bytes: []u8) []u8 {
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes[0] = ' ';
    for (bytes) |*byte| {
        if (byte.* == 0 or byte.* == '\r') byte.* = ' ';
    }
    var offset: usize = 0;
    while (offset < bytes.len) {
        const first = bytes[offset];
        if (first < 0x80) {
            offset += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(first) catch {
            bytes[offset] = ' ';
            offset += 1;
            continue;
        };
        if (offset + length > bytes.len) {
            bytes[offset] = ' ';
            offset += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(bytes[offset..][0..length]) catch {
            bytes[offset] = ' ';
            offset += 1;
            continue;
        };
        offset += length;
    }
    std.debug.assert(isPrepared(bytes));
    return bytes;
}

test "fuzz: the lexer upholds its invariants on any prepared bytes" {
    try testing.fuzz({}, lexAnything, .{ .corpus = &.{
        "func main():\n    let x = 1\n",
        "\tlet a = \"open\n",
        "0x 1.2e 99999999999999999999 007 .5\n",
        "let s = f\"a{x + 1}b{{c}}\"\n",
        "a = 1\n\n    b = '\\'\n",
        "a = \"one\\\nb = \"two\"\n",
        "a = 1 /* b */ // c\n",
        "let caf\u{00E9} = \u{201C}x\u{201D} \u{202E}\n",
        "if a:\n  b = 1\n      c = 2\n",
        "let _total = _x + word_end_ + _\n",
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
        .value(u8, '\\', 2),
        .value(u8, '\'', 2),
        .value(u8, '#', 2),
        .value(u8, '{', 2),
        .value(u8, '}', 2),
    });
    try expectInvariants(prepareInPlace(buffer[0..length]));
}

/// The vocabulary the fragment fuzzer builds programs out of: whole
/// constructs, so a random pick lands *inside* the grammar rather than
/// next to it.  Every one is either legal Luce or a mistake this file
/// has an opinion about.
const fragments = [_][]const u8{
    "func f():", "if a:",    "else:",    "while x:",    "for i in xs:",
    "let a = ",  "var b ",   "return ",  "\n",          "    ",
    "        ",  " ",        "\t",       "#note",       "//note",
    "/*",        "*/",       "(",        ")",           "[",
    "]",         ",",        ":",        ".",           "->",
    "+=",        "==",       "!",        "$",           ";",
    "0",         "007",      "1.5e-3",   "0xFF",        ".5",
    "1_0",       "1e",       "\"",       "\"a b\"",     "f\"",
    "f\"x{y}\"", "{",        "}",        "\\n",         "\\q",
    "'",         "'x'",      "x",        "caf\u{00E9}", "\u{201C}",
    "\u{00A0}",  "\u{202E}", "\u{FEFF}", "\u{1F600}",   "\x01",
    "_",         "_total",   "__",       "word_end_",
};

test "fuzz: the lexer upholds its invariants on random Luce fragments" {
    try testing.fuzz({}, lexFragments, .{ .corpus = &.{
        "\x00\x08\x09\x01\x08\x09",
        "\x27\x2a\x2b\x2c",
        "\x25\x26\x27\x08\x09\x0a",
    } });
}

fn lexFragments(_: void, smith: *testing.Smith) anyerror!void {
    var picks: [64]u8 = undefined;
    const count = smith.sliceWeightedBytes(&picks, &.{.rangeAtMost(u8, 0x00, 0xff, 1)});
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (picks[0..count]) |pick| {
        try text.appendSlice(testing.allocator, fragments[pick % fragments.len]);
    }
    try expectInvariants(prepareInPlace(text.items));
}

/// Everything that must be true of a token stream, whatever the input.
/// A fuzz target that only checks "it did not crash" proves almost
/// nothing; these are the properties the parser and the diagnostics
/// actually rely on.
fn expectInvariants(source: []u8) !void {
    const allocator = testing.allocator;
    var diagnostics = Diagnostics.init(allocator);
    defer diagnostics.deinit();
    const tokens = (try lex(allocator, source, &diagnostics)).tokens;
    defer allocator.free(tokens);

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

        // Literal tokens must survive the parser's quote-stripping.
        switch (item.kind) {
            .string_literal => try testing.expect(item.span.end - item.span.start >= 2),
            .fstring => try testing.expect(item.span.end - item.span.start >= 3),
            else => {},
        }
    }

    // The EOF token is empty and sits exactly at the end.
    const last = tokens[tokens.len - 1].span;
    try testing.expectEqual(source.len, last.start);
    try testing.expectEqual(source.len, last.end);

    // Indent and dedent are balanced: every block the lexer opens it
    // also closes, so the parser can never see a stray dedent.  Depth
    // is bounded, so an adversarial file cannot grow the stack.
    var depth: usize = 0;
    var deepest: usize = 0;
    for (tokens) |item| {
        switch (item.kind) {
            .indent => {
                depth += 1;
                deepest = @max(deepest, depth);
            },
            .dedent => {
                try testing.expect(depth > 0);
                depth -= 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 0), depth);
    try testing.expect(deepest < max_indent_depth);

    // Output is linear in the input: one token per byte at worst, plus
    // the layout each line and block can contribute.
    try testing.expect(tokens.len <= 4 * source.len + max_indent_depth + 2);

    // Every diagnostic points inside the source too, and there are
    // never more than the cap allows.
    try testing.expect(diagnostics.count() <= max_diagnostics + 1);
    for (0..diagnostics.count()) |index| {
        const item = diagnostics.at(index).?;
        try testing.expect(item.span.start <= item.span.end);
        try testing.expect(item.span.end <= source.len);
    }

    // Lexing is a pure function of the bytes.
    var again = Diagnostics.init(allocator);
    defer again.deinit();
    const repeat = (try lex(allocator, source, &again)).tokens;
    defer allocator.free(repeat);
    try testing.expectEqual(tokens.len, repeat.len);
    for (tokens, repeat) |left, right| {
        try testing.expectEqual(left.kind, right.kind);
        try testing.expectEqual(left.span.start, right.span.start);
        try testing.expectEqual(left.span.end, right.span.end);
    }

    // The one that makes silence mean something: when nothing was
    // reported, no byte was silently dropped.  Everything between two
    // tokens has to be whitespace or a comment.
    if (diagnostics.count() != 0) return;
    var cursor: usize = 0;
    for (tokens) |item| {
        if (item.span.start > cursor) try expectSkippable(source, cursor, item.span.start);
        cursor = @max(cursor, item.span.end);
    }
    try expectSkippable(source, cursor, source.len);
}

/// A region the scanner passed over must be spaces, line breaks, or
/// comments — nothing a program could have meant.
fn expectSkippable(source: []const u8, from: usize, to: usize) !void {
    var offset = from;
    while (offset < to) : (offset += 1) {
        switch (source[offset]) {
            ' ', '\n' => {},
            '#' => offset = (std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse to) - 1,
            else => {
                std.debug.print(
                    "byte 0x{X:0>2} at {d} vanished with no diagnostic\n",
                    .{ source[offset], offset },
                );
                return error.TestUnexpectedResult;
            },
        }
    }
}
