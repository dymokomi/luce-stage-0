//! Stage 2 — lexing.  Source text in, a token stream out.
//!
//! Consumes: the source bytes from stage 1.
//! Produces: a flat `[]Token`, with indentation already resolved into
//! `indent`/`dedent`/`newline` layout tokens, so the parser never
//! counts columns.
//!
//! **Complete.**  Four-space steps are canonical, tabs are rejected,
//! blank and comment-only lines produce no layout, and inside
//! parentheses newlines are plain spacing.  The lexer never fails
//! hard: malformed input becomes a `luce.lex.*` diagnostic plus the
//! closest reasonable token stream, so one bad line does not silence
//! the rest of the file.
//!
//! Flat pieces beside this file:
//!
//!   token.zig — `Kind`, `Token`, and the keyword table.
//!   lexer.zig — `lex()`: the scanner and the layout algorithm.

pub const Kind = @import("02_lex/token.zig").Kind;
pub const Token = @import("02_lex/token.zig").Token;
pub const keywords = @import("02_lex/token.zig").keywords;

pub const Error = @import("02_lex/lexer.zig").Error;
pub const lex = @import("02_lex/lexer.zig").lex;

test {
    _ = @import("02_lex/token.zig");
    _ = @import("02_lex/lexer.zig");
}
