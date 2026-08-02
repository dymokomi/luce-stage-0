//! The driver: source bytes plus a Port schema in, a verified program
//! or structured diagnostics out.
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
//!   06_mir/        the typed MIR, its verifier, and the .lc format
//!   07_optimize/   optimize    MIR              -> smaller MIR
//!   08_llvm/       lower       MIR              -> LLVM IR -> object
//!
//! Two honest irregularities, both visible in the walk below:
//! **04_semantics still emits the MIR** as it type-checks, so there is
//! no separate lowering call, and **05_hir does nothing**, so there is
//! no call at all.  docs/PIPELINE.md is the status table.
//!
//! Stage 8 is not on this path: `compileProject` stops at verified,
//! optimized MIR, which is what `luce build` writes as a `.lc` and
//! what the interpreter runs.  `luce build --backend=llvm` takes that
//! same program on to `08_llvm`.
//!
//! The compiler accepts a byte slice, never a path; diagnostics carry
//! spans into that buffer.  Every successful compile passes the MIR
//! verifier before it is returned.

const std = @import("std");
const semantics = @import("04_semantics.zig");
const mir = @import("06_mir.zig");
const optimize = @import("07_optimize.zig");
const types = @import("support/types.zig");
const diagnostics_mod = @import("support/diagnostics.zig");
const module_graph = @import("compile/modules.zig");

const Allocator = std.mem.Allocator;
const PortSchema = types.PortSchema;
const Diagnostics = diagnostics_mod.Diagnostics;

pub const Error = error{OutOfMemory};

/// How a module reaches the source of what it imports; stages 1-3 run
/// through it for every name in the graph (`compile/modules.zig`).
pub const Loader = module_graph.Loader;

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
    schema: PortSchema,
    options: types.CompileOptions,
) Error!CompileResult {
    return compileProject(gpa, source, null, schema, options);
}

/// Compile a root source plus everything it imports (a file is a
/// module; `import geo` loads geo.luc through the loader) into one
/// program.  Without a loader, imports are compile errors.
pub fn compileProject(
    gpa: Allocator,
    source: []const u8,
    loader: ?Loader,
    schema: PortSchema,
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
    const modules = (try module_graph.loadAll(gpa, scaffold, source, loader, &diagnostics)) orelse {
        program.deinit();
        return .{ .failure = diagnostics };
    };
    defer gpa.free(modules);

    // Stage 4 — resolve names, check types, validate.  And, for now,
    // stage 6's lowering too: `analyze` hands back MIR because the
    // checked walk emits it as it goes (see 04_semantics.zig's header
    // for the seam that separates them).
    const analyzed = (try semantics.analyze(arena, gpa, modules, schema, options, &diagnostics)) orelse {
        program.deinit();
        return .{ .failure = diagnostics };
    };

    // Stage 5 — HIR.  Nothing happens here: 05_hir.zig is an empty
    // seam, named so the absence is visible rather than invisible.

    // Stage 6 — MIR.  Assembling the program is all that is left,
    // since the lowering already ran inside stage 4.
    program.structs = analyzed.structs;
    program.heap_types = analyzed.heap_types;
    program.functions = analyzed.functions;
    program.constants = analyzed.constants;
    program.reads = analyzed.reads;
    program.entry_function = analyzed.entry_function;
    program.inputs = try copyPorts(arena, schema.inputs);
    program.outputs = try copyPorts(arena, schema.outputs);

    // The verifier is a compiler invariant, not a user diagnostic: a
    // verification failure here is a compiler bug surfaced loudly.
    // It runs before optimizing (so an analyzer bug is a diagnostic,
    // not an index panic inside prune) and again after (proving the
    // renumbering).
    if (try verifyStage(gpa, &program, &diagnostics, "generated")) |failed| return failed;

    // Stage 7 — optimize.  Dead-code elimination before the artifact
    // is written: a std import brings its whole module, and what a
    // program never calls should not reach the .lc, the decoder, or
    // an engine.  `luce ir --full` turns it off to show the unpruned
    // lowering.
    if (options.prune) {
        try optimize.prune(arena, &program);
        if (try verifyStage(gpa, &program, &diagnostics, "pruned")) |failed| return failed;
    }

    // Stage 8 is the caller's to ask for: `luce build --backend=llvm`
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

fn copyPorts(arena: Allocator, ports: []const types.Port) Error![]types.Port {
    const copied = try arena.alloc(types.Port, ports.len);
    for (ports, copied) |port, *slot| {
        slot.* = .{ .name = try arena.dupe(u8, port.name), .declared = port.declared };
    }
    return copied;
}

test {
    _ = @import("compile/test.zig");
}
