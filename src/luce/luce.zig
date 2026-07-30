//! Luce — the small, native language for Texel evaluators.
//!
//! docs/LUCE.md is the plan.  A Texel owns Luce source as content; the
//! compiler receives source bytes plus the Texel's Port schema and
//! produces a verified program.  The first execution engine is a
//! deterministic Luce IR interpreter behind the backend boundary; a
//! native code generator slots in behind the same boundary later
//! without changing Luce programs.

pub const source = @import("source.zig");
pub const token = @import("token.zig");
pub const lexer = @import("lexer.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const types = @import("types.zig");
pub const analyzer = @import("analyzer.zig");
pub const ir = @import("ir.zig");
pub const module = @import("module.zig");
pub const compile = @import("compile.zig");
pub const fabric = @import("fabric.zig");
pub const backend = @import("backend.zig");
pub const interpreter = @import("interpreter.zig");
pub const ownership_spec = @import("ownership_spec.zig");

test {
    _ = source;
    _ = token;
    _ = lexer;
    _ = diagnostics;
    _ = ast;
    _ = parser;
    _ = types;
    _ = analyzer;
    _ = ir;
    _ = module;
    _ = compile;
    _ = fabric;
    _ = backend;
    _ = interpreter;
    _ = ownership_spec;
}
