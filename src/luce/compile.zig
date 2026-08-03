//! The driver: source bytes in, a verified program or structured
//! diagnostics out.
//!
//! This is the file to read first.  `compileProject` below walks one
//! source file through every stage in order, and each stage is a
//! numbered folder beside this one, so the pipeline is legible from a
//! directory listing:
//!
//!   01_source/     load        bytes            -> source text
//!   02_lex/        lex         source text      -> tokens
//!   03_parse/      parse       tokens           -> AST
//!   04_semantics/  resolve, type-check, validate
//!                              AST              -> validated program
//!   05_hir/        (nothing yet — a named seam, see its header)
//!   06_mir/        build       validated        -> verified MIR
//!   07_optimize/   optimize    MIR              -> smaller MIR
//!   08_llvm/       lower       MIR              -> LLVM IR -> object
//!
//! One honest irregularity, visible in the walk below: **05_hir does
//! nothing**, so there is no call for it at all.  docs/PIPELINE.md is
//! the status table.
//!
//! Stage 8 is not on this path: `compileProject` stops at verified,
//! optimized MIR, which is what `luce build` writes as a `.lc` and
//! what the interpreter runs.  `luce build --emit=object|library|exe`
//! takes that same program on to `08_llvm`.
//!
//! The compiler accepts the root's bytes plus a `Loader`, never a
//! path: opening files is the host's, and which name resolves to what
//! is stage 1's (`01_source`).  Stage 1 registers every module it
//! loads, so a diagnostic knows which file its span indexes and a
//! failure renders with a path, a line, and a column.  Every
//! successful compile passes the MIR verifier before it is returned.

const std = @import("std");
const source_mod = @import("01_source.zig");
const semantics = @import("04_semantics.zig");
const mir = @import("06_mir.zig");
const optimize = @import("07_optimize.zig");
const types = @import("support/types.zig");
const diagnostics_mod = @import("support/diagnostics.zig");
const module_graph = @import("compile/modules.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = diagnostics_mod.Diagnostics;

pub const Error = error{OutOfMemory};

/// How a host reaches the source of what a program imports.  The seam
/// belongs to stage 1 — `01_source/load.zig` decides what is asked of
/// it and in what order — and is re-exported here because filling it
/// in is part of calling the compiler.
pub const Loader = source_mod.Loader;

pub const CompileResult = union(enum) {
    /// A verified program; caller owns it (deinit).
    success: mir.Program,
    /// Compile problems; caller owns them (deinit).  The source
    /// revision stays authoritative — there is no runnable blob.
    failure: Diagnostics,

    pub fn deinit(self: *CompileResult) void {
        switch (self.*) {
            .success => |*program| program.deinit(),
            .failure => |*diagnostics| diagnostics.deinit(),
        }
        self.* = undefined;
    }
};

/// Compile a single source with no imports available.
pub fn compile(
    gpa: Allocator,
    source: []const u8,
    options: types.CompileOptions,
) Error!CompileResult {
    return compileProject(gpa, source, null, options);
}

/// Compile a root source plus everything it imports (a file is a
/// module; `import geo` loads geo.luc through the loader) into one
/// program.  Without a loader, imports are compile errors.
pub fn compileProject(
    gpa: Allocator,
    source: []const u8,
    loader: ?Loader,
    options: types.CompileOptions,
) Error!CompileResult {
    var diagnostics = Diagnostics.init(gpa);
    errdefer diagnostics.deinit();

    var program: mir.Program = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer program.deinit();
    const arena = program.arena.allocator();

    // The AST is scaffolding: it lives in its own arena and frees as
    // soon as analysis is done with it.
    var ast_arena = std.heap.ArenaAllocator.init(gpa);
    defer ast_arena.deinit();
    const scaffold = ast_arena.allocator();

    // Stages 1-3 — load, lex, parse.  Once for the root source and
    // once for every module it imports, breadth-first, std first.
    // Every module's text lands in `diagnostics.sources`, which owns
    // it for as long as the diagnostics live.
    const modules = (try module_graph.loadAll(gpa, scaffold, source, loader, options, &diagnostics)) orelse {
        program.deinit();
        return .{ .failure = diagnostics };
    };
    defer gpa.free(modules);

    // Stage 4 — resolve names, check types, validate.  What comes back
    // is a validated program plus, per function, the operations its
    // walk decided on: a value, with nothing pointing back into the
    // checker.
    const analyzed = (try semantics.analyze(arena, gpa, modules, options, &diagnostics)) orelse {
        program.deinit();
        return .{ .failure = diagnostics };
    };

    // Stage 5 — HIR.  Nothing happens here: 05_hir.zig is an empty
    // seam, named so the absence is visible rather than invisible.

    // Stage 6 — MIR.  Close every function stage 4 recorded: seal the
    // open blocks, freeze the block lists, turn each instruction's
    // source offset into a line and a column, and assemble the
    // program.
    try mir.build.build(arena, gpa, &diagnostics.sources, analyzed, &program);

    // The verifier is a compiler invariant, not a user diagnostic: a
    // verification failure here is a compiler bug surfaced loudly.
    // It runs before optimizing (so an analyzer bug is a diagnostic,
    // not an index panic inside prune) and again after (proving the
    // renumbering).
    if (try verifyStage(gpa, &program, &diagnostics, "generated")) |failed| return failed;

    // Stage 7 — optimize.  Shrink the program before the artifact is
    // written: a std import brings its whole module, the lowering
    // leaves forwarding blocks and re-read locals behind, and the
    // ownership temporaries it parks around every fresh object are
    // mostly dead by the time the statement ends.  What a program
    // never does should not reach the .lc, the decoder, or an engine.
    // `luce ir --full` turns the stage off to show the raw lowering.
    if (options.prune) {
        try optimize.run(arena, &program, .all);
        if (try verifyStage(gpa, &program, &diagnostics, "optimized")) |failed| return failed;
    }

    // Stage 8 is the caller's to ask for: `luce build --emit=exe`
    // takes this same program on to `08_llvm`.
    diagnostics.deinit();
    return .{ .success = program };
}

/// Run the verifier and convert any failure into the internal-compiler-
/// error diagnostic; returns the failure result to bubble, null on pass.
fn verifyStage(
    gpa: Allocator,
    program: *mir.Program,
    diagnostics: *Diagnostics,
    stage: []const u8,
) Error!?CompileResult {
    mir.verify(gpa, program) catch |mistake| switch (mistake) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diagnostics.add(
                "luce.compiler.verify",
                .{ .start = 0, .end = 0 },
                "internal compiler error: {s} IR failed verification ({s})",
                .{ stage, @errorName(mistake) },
            );
            program.deinit();
            return .{ .failure = diagnostics.* };
        },
    };
    return null;
}

test {
    _ = @import("compile/test.zig");
}
