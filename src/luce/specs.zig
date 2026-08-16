//! The executable specification of Luce.
//!
//! One rule decides what lives here: **anything that runs a Luce
//! program is a specification, and a specification runs it on both
//! engines.**  Anything that inspects a structure — a token stream, an
//! AST, MIR, the LLVM IR text, the `.lcm` bytes, the interpreter's own
//! frame stack — is a test of that structure and lives beside the code
//! it proves.
//!
//! That rule is why this is a module of its own rather than part of
//! `luce`.  The second arm of every comparison is real machine code,
//! which means libLLVM, and `luce` links no LLVM on purpose (loom
//! embeds it and must not pay for it).  So the specification is the
//! one module that names both `luce` and `emit`, and `build.zig`
//! builds it as its own test target.
//!
//! `specs/agree.zig` is the harness and the place to start reading:
//! it compiles once, runs the program interpreted and compiled against
//! one shared world, and demands the same printed bytes, trap code,
//! trap message, call trace, raised error and leak census.  The
//! interpreter ships in nothing and exists to disagree
//! (docs/ENGINE.md); every spec below is one of its disagreement
//! detectors.

const builtin = @import("builtin");

/// How a spec runs a program.
pub const agree = @import("specs/agree.zig");

/// The language, feature by feature (docs/LANGUAGE.md).
pub const behavior = @import("specs/behavior_spec.zig");
/// Enums and the match statement, decision by decision
/// (docs/ENUMS.md).
pub const enums = @import("specs/enums_spec.zig");
/// Tagged unions: construction, dispatch, payload aliasing, the zero,
/// and ownership of what a member carries (docs/UNION.md).
pub const unions = @import("specs/union_spec.zig");
/// What the compiler must refuse, by stable diagnostic code.  The one
/// spec that runs nothing: a program that does not compile has no
/// engine to disagree about.
pub const errors = @import("specs/errors_spec.zig");
/// Functions as values: named functions, lambdas, and the call through
/// one (docs/FUNCTIONS.md).
pub const functions = @import("specs/functions_spec.zig");
/// Nominal interface contracts and dispatch through an interface value.
pub const interfaces = @import("specs/interfaces_spec.zig");
/// Transparent compile-time type aliases.
pub const aliases = @import("specs/aliases_spec.zig");
/// Implied receivers, inferred writers, and the `static` boundary
/// (docs/SELF.md).
pub const self = @import("specs/self_spec.zig");
/// Bound methods: the method travels with its struct (docs/BINDING.md).
pub const binding = @import("specs/binding_spec.zig");
/// File-scope values and program-root constant containers
/// (docs/CONSTANTS.md).
pub const constants = @import("specs/constants_spec.zig");
/// Threads: a worker owns its world, and the ownership model is the
/// concurrency model (docs/THREADS.md).
pub const threads = @import("specs/threads_spec.zig");
/// Several files compiled as one program (`compile/modules.zig`).
pub const modules = @import("specs/modules_spec.zig");
/// `optimize` may not change what a program does, on either engine.
pub const optimizer = @import("specs/optimize_spec.zig");
/// A serialized module read back from bytes is the same program.
pub const module_format = @import("specs/format_spec.zig");
/// The entry the compiler writes for `luce test`, run on both engines
/// like any other program (docs/TESTING.md D3).
pub const testing = @import("specs/testing_spec.zig");

/// The standard library (docs/STD.md), including the backend-neutral
/// graphics and window seams.
pub const standard = @import("specs/std_spec.zig");
/// `std.zip`: a container format, so the specification is other
/// people's bytes as well as its own.
pub const zip = @import("specs/zip_spec.zig");
/// `std.json`: a grammar, so the specification is mostly what it
/// refuses — RFC 8259 clause by clause, over JSONTestSuite's rows.
pub const json = @import("specs/json_spec.zig");

/// The binary half of the host boundary: packed byte lists, file
/// handles as ARC resources, and text as a validation
/// (docs/BYTES.md).
pub const bytes = @import("specs/bytes_spec.zig");
/// The host boundary: every effect, offered and withheld.
pub const host = @import("specs/host_spec.zig");

// The backend's end-to-end proof: source to machine code to a loaded shared
// library.  It stays beside the backend it proves and is reached only by this
// test module, because it runs programs and this is the module that can.
const backend = @import("codegen/test.zig");

/// The flagship program, driven by a scripted keyboard: the only
/// thing that says what `examples/editor/editor.luc` *does*.
pub const editor = @import("specs/editor_spec.zig");
/// The largest program in the tree, driven by a scripted player: five
/// files importing each other, played through end to end.
pub const adventure = @import("specs/adventure_spec.zig");

comptime {
    if (builtin.is_test) {
        _ = agree;
        _ = behavior;
        _ = enums;
        _ = unions;
        _ = errors;
        _ = functions;
        _ = interfaces;
        _ = aliases;
        _ = self;
        _ = binding;
        _ = constants;
        _ = threads;
        _ = modules;
        _ = optimizer;
        _ = module_format;
        _ = testing;

        _ = standard;
        _ = zip;
        _ = json;

        _ = bytes;
        _ = host;

        _ = backend;

        _ = editor;
        _ = adventure;
    }
}
