//! Stage 3 — parsing.  A token stream in, an AST out.
//!
//! Consumes: the `[]Token` from stage 2.
//! Produces: an arena-allocated `ast.Program` — declarations,
//! statements, and expressions exactly as written, with spans into the
//! source buffer.  The tree is untyped: it records syntax and asks no
//! questions about meaning.
//!
//! **Complete for the grammar in docs/LANGUAGE.md**, with one wart:
//! it desugars f-strings into `str(x) + …` and `elif` chains into
//! nested `if`s while it still has only syntax.  That belongs in
//! stage 5; nothing else here anticipates it.
//!
//! Two shapes this grammar refuses on purpose, because the languages
//! Luce reads like disagree about what they mean and both readings
//! parse (docs/LANGUAGE.md, "the two places Luce refuses to guess"):
//! `not` directly in front of a comparison (`luce.parse.precedence`),
//! and a chained comparison (`luce.parse.chain`).  Turning a silently
//! different answer into a message is the whole justification; each is
//! one guard in expressions.zig and cheap to take back out.
//!
//! What "production" means for this stage, beyond accepting the
//! language:
//!
//! * **One mistake, one diagnostic.**  A broken construct reports at
//!   the offending token, then resumes at the next line of the same
//!   block — and when the broken line was a header, its orphaned
//!   indented body is swallowed instead of being read one level out.
//!   Five unrelated errors in a file produce five useful messages.
//!   Where the intent is unmistakable the parser reads on as if the
//!   reader had written it (`if x = 1:` becomes the comparison), so
//!   the block below is still checked rather than swallowed.
//! * **Messages name the fix, not the grammar.**  `'=' assigns a
//!   value; write '==' to compare`, `unclosed '(' — no matching ')'`
//!   pointed at the opener, `missing ',' before 'y'` rather than
//!   "expected ')'", `write 'elif'`, `a call needs its parentheses`,
//!   `this 'while' block is empty`, and every "expected X" says what
//!   it found instead.  A word that opens a declaration in another
//!   language (`def`, `class`, `const`, `Func`) is answered with the
//!   Luce spelling.
//! * **A list that runs out of input blames the bracket.**  Every
//!   comma-separated list stops at a newline as well as at its closer,
//!   because a newline reaches the parser only when the group was
//!   never closed — so a truncated file reports the unclosed opener
//!   rather than demanding an element that was never coming.
//! * **Stage 2's recovery tokens are treated as recovery tokens.**  An
//!   unterminated string still yields an operand so the line parses;
//!   this stage checks whether the literal really closed and stays
//!   silent when it did not, instead of decoding the truncation and
//!   reporting a second time.  And when stage 2 stopped early on a
//!   structural bound (`Lexed.truncated`), this stage says nothing at
//!   all: the tail of that stream is stage 2 closing its own open
//!   blocks, so every complaint available here — starting with the
//!   innermost block looking empty — would be the compiler describing
//!   its own recovery.  The file was refused, by name, once.
//! * **Bounded recursion.**  Statements, conditionals, expressions,
//!   prefix chains and type arguments all take their depth through
//!   `Parser.enter`, so hostile or generated input reports
//!   `luce.parse.nesting` rather than walking off the native stack.
//! * **Bounded reporting.**  A file of noise is a hundred messages
//!   plus one `luce.parse.limit`, matching stage 2.
//!
//! Throughput on ordinary source (programs/editor.luc, ReleaseSafe) is
//! roughly 100 MB/s from bytes to AST.  Most of that is stage 2: lexing
//! the same buffer alone runs at about 150 MB/s, so the parse proper is
//! nearer 340 MB/s and is not the bottleneck.  Absolute numbers move
//! with the host; the ratio is the useful part.
//!
//! Flat pieces beside this file:
//!
//!   ast.zig         — the node types this stage produces.
//!   grammar.zig     — declarations, statements, recovery, the
//!                     recursion bound, and the `Parser` state every
//!                     piece threads.
//!   expressions.zig — the Pratt expression parser, including
//!                     f-string expansion.
//!   test.zig        — the grammar, the recovery, and the robustness
//!                     proved on their own.

pub const ast = @import("03_parse/ast.zig");

pub const Error = @import("03_parse/grammar.zig").Error;
pub const Parser = @import("03_parse/grammar.zig").Parser;
pub const parse = @import("03_parse/grammar.zig").parse;

/// A human name for a token kind, and the word behind a keyword kind:
/// the vocabulary parse diagnostics are written in.
pub const describe = @import("03_parse/grammar.zig").describe;
pub const keywordWord = @import("03_parse/grammar.zig").keywordWord;

test {
    _ = @import("03_parse/test.zig");
}
