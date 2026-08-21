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
const source_mod = @import("../source.zig");
const ast = @import("../parse.zig").ast;
const types = @import("../support/types.zig");
const mir = @import("../mir.zig");

const Type = types.Type;
const Span = source_mod.Span;
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
// reader who meets one of these in a `const` at file scope must not meet
// different words for the same mistake inside a function.  So the
// wording lives here and each pass formats it.

/// What a literal that does not fit where it landed is told, per
/// width.  Each names the type it did not fit, that type's range, and
/// **the wider type that would hold it** — which is the whole value of
/// the sentence: a reader who wrote `3000000000` did not make a
/// mistake about arithmetic, they made one about a width, and the fix
/// is a word (docs/TYPES.md §11).
pub const byte_range_message =
    "integer literal out of range; u8 holds 0 to 255 — write the place as i16";
pub const short_range_message =
    "integer literal out of range; i16 holds -32768 to 32767 — write the place as i32";
pub const int_range_message =
    "integer literal out of range; i32 holds -2147483648 to 2147483647 — write the place as i64";
pub const long_range_message =
    "integer literal out of range; i64 holds -9223372036854775808 to 9223372036854775807";
pub const half_range_message =
    "float literal is not a finite f16; f16 holds up to about 65504 — write the place as f32";
pub const float_range_message =
    "float literal is not a finite f32; f32 holds up to about 3.4e38 — write the place as f64";
pub const double_range_message =
    "float literal is not a finite number; f64 holds up to about 1.8e308";

/// The sentence for a literal that did not fit the type it landed on.
///
/// **Exhaustive on purpose.**  This used to end in an `else` that
/// answered `i64`, which is why a literal past a `u8` was once told
/// about `i64`'s range and a `f16` literal was called an integer.
/// Every width names its own range and the next rung up, and the two
/// at the top of their ladders name no rung because there is none.
pub fn rangeMessage(landed: Type) []const u8 {
    return switch (landed) {
        .u8 => byte_range_message,
        .u16, .u32, .u64, .i8 => long_range_message,
        .i16 => short_range_message,
        .i32 => int_range_message,
        .i64 => long_range_message,
        .f16 => half_range_message,
        .f32 => float_range_message,
        .f64 => double_range_message,
        .none, .boolean, .char, .str, .bytes, .foreign, .strukt, .heap, .enumeration, .variant, .function, .optional => long_range_message,
    };
}

/// The scalar type a literal going into `expected` lands on, or null
/// when the place names no scalar width (docs/TYPES.md D3).  Both the
/// ordinary lowerer and the constant folder ask this one question so
/// `u8?` and `f16?` look through their optional layer identically.
pub fn literalLandingType(expected: Type) ?Type {
    return switch (expected) {
        .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f16, .f32, .f64 => expected,
        .optional => |payload| switch (payload) {
            .u8 => .u8,
            .u16 => .u16,
            .u32 => .u32,
            .u64 => .u64,
            .i8 => .i8,
            .i16 => .i16,
            .i32 => .i32,
            .i64 => .i64,
            .f16 => .f16,
            .f32 => .f32,
            .f64 => .f64,
            // A number never lands on an enum: `Method` is a set of
            // names and `Method(8)` is the only way in (D4, R2).
            .boolean, .char, .str, .bytes, .foreign, .strukt, .heap, .enumeration, .variant, .function => null,
        },
        .none, .boolean, .char, .str, .bytes, .foreign, .strukt, .heap, .enumeration, .variant, .function => null,
    };
}

/// Binary operand typing: the operator and the two types.  Pass two
/// appends one more `{s}` of advice when one side is an optional; the
/// sentence up to there is the same.
///
/// **The sentence ends with a fact, not generic advice.** Concrete numeric
/// mismatches are handled earlier with the exact destination constructor.
/// Every pair that reaches this fallback genuinely has no conversion, so the
/// tail says exactly that.
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
        .identity => "is",
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
/// The names Luce itself owns in bare-call position: `range`, the small
/// public prelude in `builtins.zig`, and scalar conversion constructors
/// (added by `isReserved` from the type table).
///
/// Host services are deliberately absent.  Embedded standard-library
/// source reaches them through the compiler-only `Builtin` namespace and
/// publishes ordinary module declarations; a user may therefore declare a
/// function called `dir_create`, `clock_ms`, or any other implementation
/// name.  Receiver method names are absent for the same reason: `xs.append`
/// cannot collide with a module function called `append` because the
/// receiver already chooses the namespace.
pub const reserved_names = [_][]const u8{
    // Scalar conversion constructors are reserved through
    // `types.conversionNamed` in `isReserved`, directly from the one
    // builtin table that dispatches them. Container names deliberately
    // are not callable reservations: `files.list` is an ordinary and
    // useful function name.
    "range",
    "abs",
    "min",
    "max",
    "clamp",
    "sqrt",
    "floor",
    "ceil",
    "trunc",
    "len",
    "assert",
    "trap",
    "error",
    "parse_i64",
    "parse_f64",
    "parse_str",
    "print",
    "exit",
};

pub fn isReserved(name: []const u8) bool {
    if (types.conversionNamed(name) != null) return true;
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
    /// The qualification prefix its declarations carry — what the
    /// global name tables key by, and what a serialized function name
    /// begins with.  For a module of the program's own root (and for
    /// std) this is the binding; for a module of a foreign root — a
    /// package — it is `root/binding`, so two packages' same-named
    /// internals can never merge in a `.lcm` (docs/PACKAGES.md D7).
    prefix: []const u8,
    /// The namespace call sites write — the import's last segment, or
    /// the alias an `as` chose.  What refusals call the module.
    binding: []const u8,
    tree: *const ast.Program,
    file: source_mod.FileId,
};

/// What this stage hands to stage 6: struct layouts, heap-type shapes,
/// the constant pool, the entry, and one open
/// `Lowering` per function.  All of it is arena-allocated and none of
/// it points back here, so `mir.build` can close it on its own.
///
/// The shape is declared in `mir/build.zig` because it is made of
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
    /// Heap-type index whose descriptor is `.class = layout`.
    class: u32,
    enumeration: Type.EnumRef,
    variant: u32,

    pub fn asType(self: Enclosing) Type {
        return switch (self) {
            .strukt => |index| .{ .strukt = index },
            .class => |index| .{ .heap = index },
            .enumeration => |reference| .{ .enumeration = reference },
            .variant => |index| .{ .variant = index },
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

/// The three body roles represented in the shared function table. Lifecycle
/// is one closed choice rather than independent booleans: an initializer can
/// never accidentally also become a deinitializer.
pub const Lifecycle = enum { ordinary, initializer, deinitializer };

/// A collected function signature: everything a call site has to know
/// before the body it belongs to has been walked.
pub const FunctionDeclInfo = struct {
    declaration: *const ast.FuncDecl,
    name: []const u8,
    module: usize,
    parameter_types: []Type,
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
    /// (`(i64, i64)`), which is why nothing below stage 4 grows a case
    /// for multiple results: there is one value, as there always was.
    return_type: Type,
    /// Written `-> T!` or `-> !`: every call site must say `try` or
    /// `catch`, which is what makes a swallowed failure unwritable
    /// (docs/FAILURE.md).
    fallible: bool,
    /// What it fails with (docs/ERRORS.md R2): a union, or `.str` for
    /// the bare `!`.  Meaningful only when `fallible`.
    error_type: Type = .str,
    is_entry: bool,
    /// Ordinary function, class construction body, or ARC finalizer. All
    /// three use one function representation; this tag fixes the lifecycle
    /// signature and the uses of `self` which are legal in the body.
    lifecycle: Lifecycle = .ordinary,
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
    /// Compiler-written block-closure prologue bindings. Ordinary
    /// declarations and concise capture-free lambdas leave this empty.
    closure_captures: []const ClosureCaptureInfo = &.{},
};

/// One source name materialized from a block closure's environment at
/// function entry. Mutable entries additionally name the shared ARC cell.
pub const ClosureCaptureInfo = struct {
    name: []const u8,
    value_type: Type,
    mutable: bool = false,
    cell_name: ?[]const u8 = null,
    cell_layout: ?u32 = null,
    weak_cell: bool = false,
    declared_at: Span,
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

/// A collected union declaration with its module (docs/UNION.md).  The
/// members themselves live in the program's `types.VariantType` beside
/// it, the way a struct's fields live in its layout.
pub const VariantDeclInfo = struct {
    declaration: *const ast.UnionDecl,
    module: usize,
    /// One slice per collected member, parallel to the member's fields:
    /// the written default expressions (docs/UNION.md D4), folded
    /// lazily through `Analyzer.variantFieldDefault` exactly as a
    /// struct field's are.
    member_defaults: [][]FieldDefault = &.{},
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
    /// Hidden factory function installed for `init(...)`, or null while the
    /// class keeps its public memberwise constructor.
    initializer: ?u32 = null,
};

/// A transparent type alias while its target is being resolved.  The state
/// makes forward chains cheap and turns direct or indirect recursion into one
/// source diagnostic instead of native recursion.  `resolved` is meaningful
/// only in `.ready`; aliases disappear after this table.
pub const AliasDeclInfo = struct {
    declaration: *const ast.AliasDecl,
    module: usize,
    state: enum { pending, resolving, ready, failed } = .pending,
    resolved: Type = .none,
};

/// The settled contract of one interface method.  The parameter names stay
/// in the AST for diagnostics; these are the resolved types used by
/// dispatch and conformance checks.
pub const InterfaceMethodInfo = struct {
    declaration: *const ast.InterfaceMethod,
    parameter_types: []Type,
    results: []Type,
    return_type: Type,
    mutating: bool,
    fallible: bool,
    slot: u32,
    signature: u32,
};

/// A named interface and its opaque dispatch layout.  The layout index is a
/// normal struct run in MIR; only stage 4 knows that its fields are private
/// method slots rather than source-visible fields.
pub const InterfaceDeclInfo = struct {
    declaration: *const ast.InterfaceDecl,
    module: usize,
    layout: u32,
    methods: []InterfaceMethodInfo = &.{},
};

/// One explicit `struct S: I` implementation.  Method function indexes are
/// in interface declaration order and are baked into the interface value at
/// each conversion site.
pub const InterfaceConformance = struct {
    interface: u32,
    strukt: u32,
    receiver: Type,
    witness: u32,
    methods: []u32,
};

/// One struct field's default: the written expression and, once
/// folded, its value.  `expression` is null for a required field, and
/// the state machine is `ConstantInfo`'s.
pub const FieldDefault = struct {
    expression: ?*const ast.Expression = null,
    state: enum { pending, evaluating, ready, failed } = .pending,
    value: ConstantValue = .{ .integer = 0 },
    value_type: Type = .i64,
};

/// What a struct layout costs and carries, computed once for all.
pub const StructShape = struct {
    /// The struct transitively holds a heap object ("object-carrying"):
    /// the carries graph walk (`shapes.carriesObjects`) settles this.
    carries: bool = false,
    /// How many values the struct flattens to — one per scalar or
    /// object field, summed through nested structs.  Saturates just
    /// past `helpers.max_struct_values`, which is all a limit check
    /// needs and keeps the count from overflowing.
    values: u32 = 0,
};

/// The folded value of a file-scope constant.  Scalars, strings and
/// value structs are inlined at each use; a container names the
/// program-root pool row each runtime materializes once
/// (docs/CONSTANTS.md R-C).  The row, and every slice below, is
/// arena-owned by the analyzed program.
pub const ConstantValue = union(enum) {
    integer: i128,
    float: f64,
    boolean: bool,
    str: []const u8, // arena-owned
    strukt: struct { layout: u32, fields: []ConstantValue },
    container: u32,
    /// `none`, folded where something said what it is absent *of* — a
    /// `T?` annotation on the declaration is such a place, so
    /// `const x: i64? = none` folds (docs/ARGS.md D9).  It carries
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
    value: ConstantValue = .{ .integer = 0 },
    value_type: Type = .i64,
};

// ---------------------------------------------------------------------------
// Checking a body: scopes, locals, loops
// ---------------------------------------------------------------------------
//
// Pass two's working state.  It is named here rather than inside
// `builder.zig` because `FunctionBuilder` is not the only thing that
// has to speak about a local — the two passes agree on what a scope,
// a local and a loop frame are, and this is where they agree.

pub const LocalInfo = struct {
    local: LocalId,
    mutable: bool,
    /// This name denotes a zeroing non-owning slot. Reads are fresh owned
    /// upgrades, so flow facts may not assume the optional stays present.
    weak: bool = false,
    /// Where the name was written, so a second declaration of it can
    /// say where the first one is.
    declared_at: Span = .{ .start = 0, .end = 0 },
    /// True while a for-loop iterates this name: reassignment would
    /// invalidate the collection under the loop's feet (the
    /// iterator-invalidation guard).
    iterating: bool = false,
    /// A captured mutable keeps its ordinary slot for fast reads and flow
    /// facts, plus one shared ARC cell mirrored by every replacing store.
    capture_cell: ?CaptureCell = null,
};

pub const CaptureCell = struct {
    local: LocalId,
    layout: u32,
    cell_type: Type,
    value_type: Type,
    weak: bool = false,
};

/// One interned compiler-generated capture-cell class.
pub const ClosureCellLayout = struct {
    value_type: Type,
    weak: bool,
    layout: u32,
    cell_type: Type,
};

/// One local this scope has to release on the way out: the storage in
/// its slot (docs/STRINGS.md), freed at scope exit as `drop_storage`, and
/// the reference object it holds (docs/MEMORY.md), whose count scope exit
/// lowers as `release`.  A binding that owns its value — not a borrow —
/// carries one or both.
pub const Release = struct {
    local: LocalId,
    storage: bool = false,
    objects: bool = false,
};

pub const Scope = struct {
    names: std.StringHashMapUnmanaged(LocalInfo) = .empty,
    /// Locals whose storage this scope releases, in declaration order;
    /// scope exit releases them in reverse.
    owned: std.ArrayList(Release) = .empty,
};

pub const FoundLocal = struct {
    info: *LocalInfo,
};

/// Where `break` and `continue` go, and how much of the body they have
/// to unwind on the way.  The two depths are `FunctionBuilder`'s
/// `scopes` and `temps` lengths as the loop body began.
pub const LoopFrame = struct {
    /// Scope depth when the loop body began: break and continue
    /// release every scope at or above it — the unwind the recorded
    /// statements carry (nodes.Statement.Break).
    scope_depth: usize,
    /// Temporary depth when the loop body began.
    temps_depth: usize,
};

/// One declared extern (docs/FFI.md), as semantics carries it: the
/// bare symbol, the resolved Tier-1 shape, and the lock flag.
pub const ForeignDeclInfo = struct {
    symbol: []const u8,
    parameters: []const types.Type,
    result: types.Type,
    blocking: bool,
};
