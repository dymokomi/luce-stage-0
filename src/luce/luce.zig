//! Luce — a small, statically typed, compiled language.
//!
//! `docs/LANGUAGE.md` is the surface, `docs/MEMORY.md` the memory
//! model, and `docs/PIPELINE.md` the stage-by-stage status table.
//!
//! `compile.zig` is the driver and the place to start reading: it
//! walks a source file through the stage modules below, in order, and
//! produces verified MIR.  From there `codegen` compiles it, which is
//! the only way a Luce program is ever run.  The
//! `interpreter` is the test suite's differential oracle and ships in
//! nothing; it and generated code both call `runtime`, so there is one
//! implementation of every semantic (docs/ENGINE.md).
//!
//! Each stage is named for the responsibility it owns.  The order is
//! written here and in `compile.zig`, rather than encoded in filenames.

// The pipeline, in order.
pub const source = @import("source.zig");
pub const lex = @import("lex.zig");
pub const parse = @import("parse.zig");
pub const semantics = @import("semantics.zig");
pub const hir = @import("hir.zig");
pub const mir = @import("mir.zig");
pub const optimize = @import("optimize.zig");
pub const codegen = @import("codegen.zig");
pub const compile = @import("compile.zig");

// The semantics both engines share, and the one that ships in
// nothing: `interpreter` is the differential oracle the executable
// specification runs against, not a way to run a Luce program
// (docs/ENGINE.md).
pub const runtime = @import("runtime.zig");
pub const interpreter = @import("interpreter.zig");

// Cross-cutting support: not a stage, used by all of them.
pub const diagnostics = @import("support/diagnostics.zig");
pub const types = @import("support/types.zig");
pub const vocabulary = @import("support/vocabulary.zig");

// The executable specification is **not** here.  It runs every
// program on both engines, so it needs the emitter, and the emitter
// links libLLVM that this module deliberately does not
// (`src/luce/specs.zig`, docs/ENGINE.md).  `build.zig` builds it as
// its own test target.

test {
    _ = source;
    _ = lex;
    _ = parse;
    _ = semantics;
    _ = hir;
    _ = mir;
    _ = optimize;
    _ = codegen;
    _ = compile;
    _ = runtime;
    _ = interpreter;
    _ = diagnostics;
    _ = types;
    _ = vocabulary;
}
