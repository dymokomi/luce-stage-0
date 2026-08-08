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
const Span = source_mod.Span;
const BlockId = mir.BlockId;
const LocalId = mir.LocalId;

/// The stage's error set.  Checking never fails on a bad program — that
/// is a diagnostic — so the only way out is running out of memory.
pub const Error = error{OutOfMemory};

// ---------------------------------------------------------------------------
// Messages both passes say
// ---------------------------------------------------------------------------
//
// A constant folder and a lowering walk legitimately differ in what
// they do with an answer; they must not differ in the answer, and a
// reader who meets one of these in a `let` at file scope must not meet
// different words for the same mistake inside a function.  So the
// wording lives here and each pass formats it.

/// What a literal that does not fit where it landed is told, per
/// width.  Each names the type it did not fit, that type's range, and
/// **the wider type that would hold it** — which is the whole value of
/// the sentence: a reader who wrote `3000000000` did not make a
/// mistake about arithmetic, they made one about a width, and the fix
/// is a word (docs/TYPES.md §11).
pub const byte_range_message =
    "integer literal out of range; byte holds 0 to 255 — write the place as a short";
pub const short_range_message =
    "integer literal out of range; short holds -32768 to 32767 — write the place as an int";
pub const int_range_message =
    "integer literal out of range; int holds -2147483648 to 2147483647 — write the place as a long";
pub const long_range_message =
    "integer literal out of range; long holds -9223372036854775808 to 9223372036854775807";
pub const half_range_message =
    "float literal is not a finite half; half holds up to about 65504 — write the place as a float";
pub const float_range_message =
    "float literal is not a finite float; float holds up to about 3.4e38 — write the place as a double";
pub const double_range_message =
    "float literal is not a finite number; double holds up to about 1.8e308";

/// The sentence for a literal that did not fit the type it landed on.
///
/// **Exhaustive on purpose.**  This used to end in an `else` that
/// answered `long`, which is why a literal past a `byte` was once told
/// about `long`'s range and a `half` literal was called an integer.
/// Every width names its own range and the next rung up, and the two
/// at the top of their ladders name no rung because there is none.
pub fn rangeMessage(landed: Type) []const u8 {
    return switch (landed) {
        .byte => byte_range_message,
        .short => short_range_message,
        .int => int_range_message,
        .long => long_range_message,
        .half => half_range_message,
        .float => float_range_message,
        .double => double_range_message,
        .none, .boolean, .string, .strukt, .heap, .enumeration, .function, .optional => long_range_message,
    };
}

/// Binary operand typing: the operator and the two types.  Pass two
/// appends one more `{s}` of advice when one side is an optional; the
/// sentence up to there is the same.
///
/// **The sentence ends with a fact, not with advice.**  It used to
/// offer "conversions are explicit, so write long(...) or double(...)",
/// because `long` against `double` was the one mismatch a constructor
/// could repair.  It is not a mismatch any more — `long` widens to
/// `double` on its own (docs/NUMERICS.md) — so every pair that still
/// reaches this message genuinely has nothing to convert between, and
/// the tail says exactly that.
pub const mismatched_operands_message =
    "operands of {s} are {s} and {s}, and there is no conversion between them";

/// How an operator is written, for a message that has to name it.
pub fn operatorText(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .subtract => "-",
        .multiply => "*",
        .divide => "/",
        .floor_divide => "//",
        .modulo => "%",
        .equal => "==",
        .not_equal => "!=",
        .less => "<",
        .less_equal => "<=",
        .greater => ">",
        .greater_equal => ">=",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .shift_left => "<<",
        .shift_right => ">>",
        .logic_and => "and",
        .logic_or => "or",
        .coalesce => "else",
        .catch_error => "catch",
    };
}

/// Struct construction, the three ways it goes wrong.
pub const namespace_has_no_fields_message =
    "{s} is a function namespace and has no value fields";
pub const duplicate_field_message = "field {s} given twice";
pub const missing_field_message = "{s} is missing {s}";

/// The second half of `missing_field_message`: every field the
/// construction left out, in declaration order, as English —
/// `field b`, or `fields b, c, and d`.
///
/// Reporting only the first hole made a fourteen-field struct take
/// thirteen compile rounds to finish, one field revealed per round.
/// The whole set is known at the point of the message; a reader who
/// has to run the compiler again to learn the next word of the same
/// sentence is being made to do the compiler's work.
///
/// The caller owns `written`.
pub fn writeMissingFields(
    written: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    layout: types.StructLayout,
    seen: []const bool,
) error{OutOfMemory}!void {
    var missing: usize = 0;
    for (seen) |given| {
        if (!given) missing += 1;
    }
    try written.appendSlice(allocator, if (missing == 1) "field " else "fields ");
    var written_so_far: usize = 0;
    for (seen, 0..) |given, index| {
        if (given) continue;
        if (written_so_far != 0) {
            // `b and c`, but `b, c, and d`: two names take no comma.
            if (missing > 2) try written.appendSlice(allocator, ",");
            try written.appendSlice(allocator, " ");
            if (written_so_far + 1 == missing) try written.appendSlice(allocator, "and ");
        }
        try written.appendSlice(allocator, layout.fields[index].name);
        written_so_far += 1;
    }
}

// ---------------------------------------------------------------------------
// Reserved names
// ---------------------------------------------------------------------------

/// Names the language reserves; nothing user-declared may take them.
///
/// **Every free builtin belongs here**, and a test in `builder.zig`
/// reads that table against this list so the next one added cannot be
/// left out.  It was left out seven times: the `term_*` services
/// arrived without their names, so a program could declare
/// `func term_rows():` over the builtin and get whichever the
/// resolver reached first.
///
/// **Most method names are deliberately not here** — `sort`, `find`,
/// `contains`, `clear`, `keys`, `values`, `get`, `build` and the rest
/// are resolved by receiver type, so a function called `sort` collides
/// with nothing.  **Seven are here anyway**: `append`, `insert`,
/// `pop`, `remove`, `has`, `dim` and `byte_at`.  Nothing in the
/// resolver needs them to be — a method call names its receiver — so
/// the rule a reader can predict from this list is not the rule the
/// list states, and the cost is real: `std.files` spells
/// `append_text` because `append` is here, and `std.json` offers no
/// `has` beside its `get` for the same reason.  Whether those seven
/// should stay is a language question and not a resolver one; until it
/// is answered, this paragraph is the answer to "why can I write
/// `func sort` and not `func has`".
pub const reserved_names = [_][]const u8{
    // The three conversion constructors (docs/TYPES.md D8).  The
    // container names are deliberately *not* here: `list` and `map`
    // are answers only in type position, where `resolveBase` decides
    // and a struct of that name is refused where it is declared —
    // reserving them as callables buys nothing and costs `files.list`,
    // which is the right name for what it does.
    "range",       "long",         "double",          "string",              "None",
    "abs",         "min",          "max",             "clamp",               "sqrt",
    "floor",       "ceil",         "trunc",           "len",                 "byte_at",
    "assert",      "trap",         "parse_int",       "parse_float",         "chr",
    "ord",         "append",       "pop",             "insert",              "remove",
    "has",         "dim",          "free",            "print",               "file_read",
    "file_write",  "file_exists",  "key_read",        "key_text",            "error",
    "read_line",   "print_error",  "clock_ms",        "sleep_ms",            "env",
    "file_append", "file_delete",  "file_rename",     "dir_list",            "term_rows",
    "term_cols",   "term_clear",   "term_move",       "term_style",          "term_write",
    "term_flush",  "exit",         "os_total_memory", "os_available_memory", "os_cpu_count",
    "file_open",   "parse_string",
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

/// What a function was declared inside: a struct, or an enum
/// (docs/ENUMS.md D7 — an enum takes the methods and namespace
/// functions a struct has, under the same rules).  It is what gives
/// `self` its type, and what makes `self` at file scope a diagnostic
/// rather than a crash.
pub const Enclosing = union(enum) {
    strukt: u32,
    enumeration: Type.EnumRef,

    pub fn asType(self: Enclosing) Type {
        return switch (self) {
            .strukt => |index| .{ .strukt = index },
            .enumeration => |reference| .{ .enumeration = reference },
        };
    }
};

/// One local visible where a lambda was written.  A lifted lambda does
/// not carry its value, but it retains the name and declaration span so
/// capture and no-shadowing diagnostics can still describe the lexical
/// scope the source actually has.
pub const EnclosingLocal = struct {
    name: []const u8,
    declared_at: Span,
};

/// The semantic receiver effect inferred for a member.  Source no
/// longer writes a receiver parameter; plain members begin as readers
/// and the declaration fixed point promotes the ones that write self.
pub const Receiver = enum { not, reads, writes };

/// A collected function signature: everything a call site has to know
/// before the body it belongs to has been walked.
pub const FunctionDeclInfo = struct {
    declaration: *const ast.FuncDecl,
    name: []const u8,
    module: usize,
    parameter_types: []Type,
    parameter_modes: []ast.ParameterMode,
    /// One entry per parameter: the folded default where the
    /// declaration wrote one (docs/ARGS.md D2), null where the
    /// parameter is required.  Defaults are trailing (D3), so the
    /// non-null entries are a suffix.  A call site materialises a
    /// missing argument from here as the constant register the same
    /// literal would have produced written out — nothing reaches MIR.
    parameter_defaults: []?TypedConstant,
    /// Whether this member has the implicit `self`, and whether its
    /// body (directly or transitively) writes that receiver
    /// (docs/SELF.md).  `.not` for top-level and `static` functions.
    ///
    /// The receiver's *type* is `parameter_types[0]`: readers pass its
    /// value as an ordinary first argument, while writers carry its
    /// caller place over `call_inout`.  This field is what says the
    /// call site may spell either one as `x.f(…)`.
    receiver: Receiver = .not,
    /// The declaration this function was written inside, or null at top
    /// level.  Set for namespace functions too — `self` outside one is
    /// refused by asking this, not by asking the receiver.
    enclosing: ?Enclosing = null,
    /// What the function answers, in order: empty for a function that
    /// answers nothing, one entry for `-> T`, two or more for a return
    /// shape (docs/RETURNS.md).  This is the arity a call site sees.
    results: []Type = &.{},
    /// What actually travels in the value channel.  SELF retired the
    /// old hidden receiver-at-result-zero convention, so this is now
    /// `results` exactly for every function.
    channel: []Type = &.{},
    /// The one type that travels in the value channel.  For a return
    /// shape it is the compiler-synthesized struct the values ride in
    /// (`(long, long)`), which is why nothing below stage 4 grows a case
    /// for multiple results: there is one value, as there always was.
    return_type: Type,
    /// Written `-> T!` or `-> !`: every call site must say `try` or
    /// `catch`, which is what makes a swallowed failure unwritable
    /// (docs/FAILURE.md).
    fallible: bool,
    is_entry: bool,
    /// Set only on the function a **lambda** became (docs/FUNCTIONS.md
    /// D2): every local in scope where the lambda was written.
    ///
    /// A lambda carries no environment, so its body is checked in a
    /// scope holding its parameters and nothing else — which makes a
    /// reach into the enclosing frame an *unknown name*, and that is
    /// true and useless.  This is what lets the refusal say the thing
    /// the reader needs instead: the name is right there, and it is not
    /// reachable from here.  Null for every declared function, which
    /// has no enclosing frame to speak of.
    enclosing_locals: ?[]const EnclosingLocal = null,
};

/// A collected enum declaration with its module (docs/ENUMS.md).  The
/// members themselves live in the program's `types.EnumType` beside
/// it, the way a struct's fields live in its layout.
pub const EnumDeclInfo = struct {
    declaration: *const ast.EnumDecl,
    module: usize,
    /// Whether this enum's member values have been folded yet.  They
    /// are folded in declaration order, so a member expression naming a
    /// member of an enum still pending is refused rather than read at
    /// whatever its slot happens to hold.
    settled: bool = false,
};

/// A collected struct declaration with its module, for cycle spans
/// and field resolution.
pub const StructDeclInfo = struct {
    declaration: *const ast.StructDecl,
    module: usize,
    /// One entry per *collected* field, in layout order (docs/ARGS.md
    /// D8).  Folded lazily through `Analyzer.fieldDefault`, because a
    /// default may construct another struct and lean on its defaults
    /// in turn — the same lazy, cycle-checked shape a file-scope
    /// constant has.
    field_defaults: []FieldDefault = &.{},
    /// One entry per collected field, beside `field_defaults`: the
    /// visibility the field wrote (docs/VISIBILITY.md §3).
    /// `types.StructLayout` stays untouched — the ARGS step-5
    /// precedent: what lowering needs lives in the layout, what
    /// checking needs lives here.
    field_visibility: []ast.Visibility = &.{},
};

/// One struct field's default: the written expression and, once
/// folded, its value.  `expression` is null for a required field, and
/// the state machine is `ConstantInfo`'s.
pub const FieldDefault = struct {
    expression: ?*const ast.Expression = null,
    state: enum { pending, evaluating, ready, failed } = .pending,
    value: ConstantValue = .{ .long = 0 },
    value_type: Type = .long,
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
/// only — scalars, string, and value structs — computed entirely at
/// compile time and inlined at every use site.
pub const ConstantValue = union(enum) {
    long: i64,
    double: f64,
    boolean: bool,
    string: []const u8, // arena-owned
    strukt: struct { layout: u32, fields: []ConstantValue },
    /// `none`, folded where something said what it is absent *of* — a
    /// `T?` annotation on the declaration is such a place, so
    /// `let x: long? = none` folds (docs/ARGS.md D9).  It carries
    /// nothing; the constant's type says all there is.
    absent,
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
    value: ConstantValue = .{ .long = 0 },
    value_type: Type = .long,
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
/// `inout_receiver` is the caller's owning binding seen through an
/// implicit writing `self`: it may replace/rebind that place, but the
/// callee may neither move it nor release it at scope exit.
/// Bindings of value types are all `.alias` — the class never matters.
pub const OwnershipClass = enum { owned, alias, borrow_param, inout_receiver };

pub const Poison = enum { given, freed };

pub const LocalInfo = struct {
    local: LocalId,
    mutable: bool,
    /// Where the name was written, so a second declaration of it can
    /// say where the first one is.
    declared_at: Span = .{ .start = 0, .end = 0 },
    class: OwnershipClass = .alias,
    /// The local's type is an object or an object-carrying struct.
    carries: bool = false,
    /// For an `.alias` binding written as `let y = x`, the name that
    /// actually owns the object — resolved through a chain of aliases
    /// to its root, so a refusal can say which name to give instead
    /// (S23).  Null when the alias came from something with no name to
    /// offer: a container read, a field, a call.
    owner_name: ?[]const u8 = null,
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
/// string fields — so they are answered separately.
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
