//! Stage 2 — lexing.  Source text in, a token stream out.
//!
//! Consumes: the source bytes from stage 1.
//! Produces: a flat `[]Token`, with indentation already resolved into
//! `indent`/`dedent`/`newline` layout tokens, so the parser never
//! counts columns.
//!
//! **Locked.**  Complete for the lexical surface Luce has, with every
//! open question closed rather than left to taste:
//!
//! * **Its input is stage 1's prepared text** — valid UTF-8, LF only,
//!   no NUL, no BOM — and that is a documented precondition, asserted
//!   in Debug, not re-checked.  Encoding is loading's to decide; this
//!   stage has no CRLF path and no UTF-8 validation of its own.
//! * **The four-space step is enforced**, not merely canonical: a
//!   block opens exactly four columns deeper than the one containing
//!   it, tabs are rejected outright (and recovered as four-column
//!   stops), and nesting is bounded.  A language whose blocks *are*
//!   their indentation cannot leave the size of a step to taste.
//! * **A source file must read the way it runs**: bidirectional
//!   controls are refused everywhere including strings and comments
//!   (CVE-2021-42574), raw control bytes are refused inside text, and
//!   a Unicode look-alike is named with the ASCII to write instead.
//!
//! Blank and comment-only lines produce no layout, and inside
//! parentheses or map-literal braces newlines are plain spacing.  The lexer never fails
//! hard: malformed input becomes a `luce.lex.*` diagnostic plus the
//! closest reasonable token stream — including a recovery token where
//! a value was clearly meant — so one bad construct does not silence
//! the rest of the file.  Reporting is bounded twice (identical runs
//! collapse, then a hard cap), so untrusted bytes cannot turn into
//! unbounded error text.  `lexer.zig`'s header is the full statement
//! of the surface and the recovery contract.
//!
//! **What is deliberately not here**, because each is a language
//! decision and not a lexer one (docs/MISSING.md): hex, binary and
//! octal literals, digit separators, escapes beyond `\n \t \\ \"`,
//! non-ASCII identifiers, block comments, and character literals.
//! Every one of them is *diagnosed by name* rather than silently
//! mis-lexed, so the day one is adopted, this is the only file that
//! changes — except the escape set, whose other half (decoding) is
//! stage 3's, and which therefore moves as one change across two
//! stages or not at all.
//!
//! Flat pieces beside this file:
//!
//!   token.zig — `Kind`, `Token`, and the keyword table.
//!   lexer.zig — `lex()`: the scanner and the layout algorithm.

pub const Kind = @import("lex/token.zig").Kind;
pub const Token = @import("lex/token.zig").Token;
pub const keywords = @import("lex/token.zig").keywords;

pub const Error = @import("lex/lexer.zig").Error;
pub const lex = @import("lex/lexer.zig").lex;

test {
    _ = @import("lex/token.zig");
    _ = @import("lex/lexer.zig");
}
