//! Stage 4's shared vocabulary: the words both passes speak.
//!
//! Pass one (`declarations.zig`) collects declarations; pass two
//! (`builder.zig`) walks every function body against what pass one
//! collected.  The two are a real seam — one runs before the other and
//! neither is the other's inside — but they need a common language:
//! what a collected function is, what a folded constant is, and what a
//! scope, a local and a loop frame are while a body is being checked.
//!
//! That language lives here rather than in either pass, because a pass
//! that exports its own working state to the pass beside it is not a
//! seam at all.  Everything here is plain data with no behaviour beyond
//! one reserved-name predicate; the passes hold it, this file names it.
//!
//! Precedent: Go keeps the node and symbol vocabulary in
//! `cmd/compile/internal/ir` and runs `typecheck` and `walk` over it;
//! Rust keeps it in `rustc_middle::ty` under `rustc_hir_analysis` and
//! `rustc_hir_typeck`.  Neither has a pass exporting its state sideways.

const std = @import("std");
const source_mod = @import("../01_source.zig");
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");
const mir = @import("../06_mir.zig");

const Type = types.Type;
const BlockId = mir.BlockId;
const LocalId = mir.LocalId;

/// The stage's error set.  Checking never fails on a bad program — that
/// is a diagnostic — so the only way out is running out of memory.
pub const Error = error{OutOfMemory};

/// Both passes reject a bad literal, and a reader who sees one
/// message should not get a different one from the other pass.
pub const integer_range_message =
    "integer literal out of range; Int holds -9223372036854775808 to 9223372036854775807";
pub const float_range_message =
    "float literal is not a finite number; Float holds up to about 1.8e308";

// ---------------------------------------------------------------------------
// Reserved names
// ---------------------------------------------------------------------------

/// Names the language reserves; nothing user-declared may take them.
pub const reserved_names = [_][]const u8{
    "range",       "Int",        "Float",       "Bool",        "String",
    "List",        "Map",        "Array",       "Builder",     "None",
    "abs",         "min",        "max",         "clamp",       "sqrt",
    "floor",       "ceil",       "len",         "slice",       "byte_at",
    "assert",      "trap",       "str",         "parse_int",   "parse_float",
    "chr",         "ord",        "append",      "pop",         "insert",
    "remove",      "has",        "dim",         "free",        "print",
    "file_read",   "file_write", "file_exists", "arg",         "arg_count",
    "key_read",    "key_text",   "error",       "read_line",   "print_error",
    "clock_ms",    "sleep_ms",   "env",         "file_append", "file_delete",
    "file_rename", "dir_list",
};

pub fn isReserved(name: []const u8) bool {
    for (reserved_names) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// What the stage takes in and hands over
// ---------------------------------------------------------------------------

/// One file in a project: the root ("" prefix) or an imported module
/// whose declarations are namespaced by its import name.  `file` is
/// its entry in stage 1's registry — the text its spans index, the
/// path debug info reports, and the line index origins are read from.
pub const ModuleTree = struct {
    prefix: []const u8,
    tree: *const ast.Program,
    file: source_mod.FileId,
};

/// What this stage hands to stage 6: struct layouts, heap-type shapes,
/// the constant pool, the entry, and one open
/// `Lowering` per function.  All of it is arena-allocated and none of
/// it points back here, so `mir.build` can close it on its own.
///
/// The shape is declared in `06_mir/build.zig` because it is made of
/// MIR; naming it here keeps the stage's vocabulary its own.
pub const Analyzed = mir.build.Lowered;

// ---------------------------------------------------------------------------
// Collected declarations
// ---------------------------------------------------------------------------

/// A collected function signature: everything a call site has to know
/// before the body it belongs to has been walked.
pub const FunctionDeclInfo = struct {
    declaration: *const ast.FuncDecl,
    name: []const u8,
    module: usize,
    parameter_types: []Type,
    parameter_modes: []ast.ParameterMode,
    return_type: Type,
    /// Written `-> T!` or `-> !`: every call site must say `try` or
    /// `catch`, which is what makes a swallowed failure unwritable
    /// (docs/FAILURE.md).
    fallible: bool,
    is_entry: bool,
};

/// A collected struct declaration with its module, for cycle spans
/// and field resolution.
pub const StructDeclInfo = struct {
    declaration: *const ast.StructDecl,
    module: usize,
};

/// What a struct layout costs and carries, computed once for all.
pub const StructShape = struct {
    /// The struct transitively holds a heap object, so the ownership
    /// rules apply to it (S27's "object-carrying").
    carries: bool = false,
    /// How many values the struct flattens to — one per scalar or
    /// object field, summed through nested structs.  Saturates just
    /// past `helpers.max_struct_values`, which is all a limit check
    /// needs and keeps the count from overflowing.
    values: u32 = 0,
};

/// The folded value of a file-scope constant.  Constants are values
/// only — scalars, String, and value structs — computed entirely at
/// compile time and inlined at every use site.
pub const ConstantValue = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8, // arena-owned
    strukt: struct { layout: u32, fields: []ConstantValue },
};

pub const TypedConstant = struct {
    value: ConstantValue,
    value_type: Type,
};

pub const ConstantInfo = struct {
    declaration: *const ast.ConstDecl,
    module: usize,
    /// Lazy evaluation with cycle detection: constants may reference
    /// each other across modules in any order, but never in a loop.
    state: enum { pending, evaluating, ready, failed } = .pending,
    value: ConstantValue = .{ .int = 0 },
    value_type: Type = .int,
};

// ---------------------------------------------------------------------------
// Checking a body: scopes, locals, loops
// ---------------------------------------------------------------------------
//
// Pass two's working state.  It is named here rather than inside
// `builder.zig` because `FunctionBuilder` is not the only thing that
// has to speak about a local's ownership class — the two passes agree
// on what "owned" means, and this is where they agree.

/// How a binding relates to the object it holds (OWNERSHIP.md):
/// `owned` bindings received something fresh, a give, or a give
/// parameter — their scope frees the object; `alias` bindings are just
/// another name (S8); `borrow_param` marks a borrowed parameter, which
/// may never keep, give, free, or return its object (S12, S17).
/// Bindings of value types are all `.alias` — the class never matters.
pub const OwnershipClass = enum { owned, alias, borrow_param };

pub const Poison = enum { given, freed };

pub const LocalInfo = struct {
    local: LocalId,
    mutable: bool,
    class: OwnershipClass = .alias,
    /// The local's type is an object or an object-carrying struct.
    carries: bool = false,
    /// Set by give/free in lowering (= source) order; any later use in
    /// this scope is a compile error (S10, S29).
    poisoned: ?Poison = null,
    /// True while a for-loop iterates this name: reassignment would
    /// free the collection under the loop's feet (S5 meets S9).
    iterating: bool = false,
};

/// One local this scope has to release on the way out, and in which of
/// the two senses it owns something: the objects bound to it (S1-S43),
/// the storage in its slot (docs/STRINGS.md), or both.  They are
/// separate questions — `let b = a` aliases a's objects and copies its
/// String fields — so they are answered separately.
pub const Release = struct {
    local: LocalId,
    objects: bool = false,
    storage: bool = false,
};

pub const Scope = struct {
    names: std.StringHashMapUnmanaged(LocalInfo) = .empty,
    /// Locals this scope releases, in declaration order; scope exit
    /// releases them in reverse.
    owned: std.ArrayList(Release) = .empty,
};

pub const FoundLocal = struct {
    info: *LocalInfo,
    /// Index of the scope that declared the name (S30 loop guard).
    depth: usize,
};

/// Where `break` and `continue` go, and how much of the body they have
/// to unwind on the way.  The two depths are `FunctionBuilder`'s
/// `scopes` and `temps` lengths as the loop body began.
pub const LoopFrame = struct {
    continue_block: BlockId,
    exit_block: BlockId,
    /// Scope depth when the loop body began: break and continue
    /// release every scope at or above it.
    scope_depth: usize,
    /// Temporary depth when the loop body began.
    temps_depth: usize,
};
