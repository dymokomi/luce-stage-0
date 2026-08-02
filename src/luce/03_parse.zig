//! Stage 3 — parsing.  A token stream in, an AST out.
//!
//! Consumes: the `[]Token` from stage 2.
//! Produces: an arena-allocated `ast.Program` — declarations,
//! statements, and expressions exactly as written, with spans into the
//! source buffer.  The tree is untyped: it records syntax and asks no
//! questions about meaning.
//!
//! **Complete.**  Handwritten recursive descent for declarations and
//! statements with a Pratt expression parser.  The parser recovers at
//! line and block boundaries, so one edit produces several useful
//! `luce.parse.*` diagnostics instead of one, and expression nesting is
//! bounded so hostile input reports rather than overflowing the stack.
//!
//! Flat pieces beside this file:
//!
//!   ast.zig         — the node types this stage produces.
//!   grammar.zig     — declarations, statements, and the `Parser`
//!                     state every piece threads.
//!   expressions.zig — the Pratt expression parser, including
//!                     f-string expansion.
//!   test.zig        — the syntax proved on its own.

pub const ast = @import("03_parse/ast.zig");

pub const Error = @import("03_parse/grammar.zig").Error;
pub const Parser = @import("03_parse/grammar.zig").Parser;
pub const parse = @import("03_parse/grammar.zig").parse;

test {
    _ = @import("03_parse/test.zig");
}
