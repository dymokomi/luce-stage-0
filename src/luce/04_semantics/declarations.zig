//! Luce semantic analysis — pass one, and the drive of pass two.
//!
//! Declaration collection first: struct layouts and their shapes, enum
//! tables, function signatures, file-scope constants, the selected
//! entry.  Then `builder.zig` walks every function body, checking it
//! and recording what it decides on stage 6's tape.  The type checker
//! knows Luce types and nothing else; nothing about any backend
//! appears here.
//!
//! **Collection, not evaluation.**  A constant, an enum member's value
//! and a default are all *folded* by `constants.zig`, which this file
//! calls at four points and does not otherwise contain: it registers
//! the names, and the evaluator turns an expression into a value.  The
//! two are separate because the folding order is not the collection
//! order — an enum member's value may name a constant and a constant
//! may name an enum member, so every name has to exist before either
//! fold runs (docs/ENUMS.md D8).
//!
//! Rules enforced here, per docs/LANGUAGE.md: static types with no
//! implicit numeric conversion, immutable let and parameters, no
//! shadowing, definite initialization (bindings always carry a value),
//! and return on every path.
//!
//! What the two passes both speak is `context.zig`, not this file: the
//! collected declarations, the folded constants, and the scope, local
//! and loop state a body is checked against are named there so neither
//! pass exports its working state to the other.

const std = @import("std");
const source_mod = @import("../01_source.zig");
const helpers = @import("helpers.zig");
const builder_mod = @import("builder.zig");
const context = @import("context.zig");

// Compile-time evaluation: the folder every constant, enum value and
// default goes through (`constants.zig`).
const constants = @import("constants.zig");
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");
const mir = @import("../06_mir.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const Type = types.Type;
const StructLayout = types.StructLayout;
const Diagnostics = diagnostics_mod.Diagnostics;
const Register = mir.Register;
const LocalId = mir.LocalId;

// The stage's shared vocabulary, spelled unqualified here because this
// file is one of its two speakers (`04_semantics/context.zig`).
const Error = context.Error;
const Analyzed = context.Analyzed;
const ModuleTree = context.ModuleTree;
const FunctionDeclInfo = context.FunctionDeclInfo;
const StructDeclInfo = context.StructDeclInfo;
const StructShape = context.StructShape;
const TypedConstant = context.TypedConstant;
const ConstantInfo = context.ConstantInfo;
const OwnershipClass = context.OwnershipClass;
const isReserved = context.isReserved;

/// Reporting cap, matching stages 2 and 3.  One broken declaration
/// can make every line after it wrong; a reader wants the first
/// hundred, and an untrusted file must not be able to spend the
/// host's memory on messages nobody will read.
pub const max_diagnostics: u32 = 100;

/// One closed instantiation of a compiler-owned standard-library body.
/// This is deliberately not a generic-function table: source cannot
/// add a row, and the only producer validates that its template came
/// from an embedded standard module.
const StandardSpecialization = struct {
    template: u32,
    parameters: []const Type,
    function: u32,
};

/// Check the project and lower it to IR.  Returns null when errors
/// were reported; the diagnostics tell the story.
pub fn analyze(
    arena: Allocator,
    temporary: Allocator,
    modules: []const ModuleTree,
    options: types.CompileOptions,
    diagnostics: *Diagnostics,
) Error!?Analyzed {
    // Arena-allocated because the lowerings this stage hands over
    // point at it while they are being recorded, and they outlive the
    // analyzer itself.
    const pool = try arena.create(mir.build.ConstantPool);
    pool.* = .{ .arena = arena, .scratch = temporary };
    var analyzer: Analyzer = .{
        .arena = arena,
        .temporary = temporary,
        .modules = modules,
        .options = options,
        .diagnostics = diagnostics,
        .pool = pool,
    };
    defer analyzer.deinitScratch();
    return analyzer.run();
}

// ---------------------------------------------------------------------------
// Analyzer — the collected project, and pass one over it
// ---------------------------------------------------------------------------

/// What pass one collected, and the queries pass two asks of it.
///
/// Pass two (`builder.zig`) holds one of these for the whole walk and
/// reads the tables below through the methods on it; everything else
/// here runs once, before any body is checked.
pub const Analyzer = struct {
    arena: Allocator,
    temporary: Allocator,
    modules: []const ModuleTree,
    options: types.CompileOptions,
    diagnostics: *Diagnostics,

    /// Diagnostics this analysis has added, for the report cap.
    /// Counted here rather than read from `diagnostics`, which the
    /// earlier stages have already written into.
    reported: u32 = 0,

    structs: std.ArrayList(StructLayout) = .empty,
    struct_decls: std.ArrayList(StructDeclInfo) = .empty,
    /// One entry per struct, filled once the layouts settle: whether
    /// the struct transitively holds an object, and how many values it
    /// expands to.  Both were recursive queries answered on demand,
    /// and both are exponential that way — a struct with two struct
    /// fields visits its children twice per level, so twenty levels
    /// is a million walks of the same table.  Computed once, in
    /// dependency order, they are array reads.
    struct_shapes: std.ArrayList(StructShape) = .empty,
    heap_types: std.ArrayList(types.HeapType) = .empty,
    /// One row per distinct function type the program writes
    /// (docs/FUNCTIONS.md S2), interned exactly as heap shapes are, so
    /// two identically written signatures are one type.
    signatures: std.ArrayList(types.Signature) = .empty,
    struct_names: std.StringHashMapUnmanaged(u32) = .empty,
    /// The declared enums, in declaration order (docs/ENUMS.md).  They
    /// share the type-name space with structs — a program that declares
    /// both `struct Method` and `enum Method` has declared one name
    /// twice — so `firstDeclarationOf` reads both.
    enums: std.ArrayList(types.EnumType) = .empty,
    enum_decls: std.ArrayList(context.EnumDeclInfo) = .empty,
    enum_names: std.StringHashMapUnmanaged(u32) = .empty,
    /// The declared unions, in declaration order (docs/UNION.md).  They
    /// share the type-name space with structs and enums — one name, one
    /// declaration, whichever keyword wrote it — so `firstDeclarationOf`
    /// reads all three.
    variants: std.ArrayList(types.VariantType) = .empty,
    variant_decls: std.ArrayList(context.VariantDeclInfo) = .empty,
    variant_names: std.StringHashMapUnmanaged(u32) = .empty,
    /// One entry per union, filled by the same graph walk that settles
    /// `struct_shapes`: whether any member's field transitively holds
    /// an object (D9's OR over the members), and the type's
    /// unconditional expansion — one for the tag plus the largest
    /// member's (D12).
    variant_shapes: std.ArrayList(StructShape) = .empty,
    functions: std.ArrayList(FunctionDeclInfo) = .empty,
    function_names: std.StringHashMapUnmanaged(u32) = .empty,
    standard_specializations: std.ArrayList(StandardSpecialization) = .empty,
    /// The program's string constants.  A `Program` field, so the
    /// pool and its interning live in stage 6; this stage fills it as
    /// literals type-check.
    pool: *mir.build.ConstantPool,
    constant_infos: std.ArrayList(ConstantInfo) = .empty,
    constant_names: std.StringHashMapUnmanaged(u32) = .empty,

    /// What the fold underway is *for*, when it is not a file-scope
    /// `const`: "a default" while a parameter or field default folds
    /// (docs/ARGS.md D2), null otherwise.  The folder's answer never
    /// changes with it — only the sentence a refusal opens with, so a
    /// reader who wrote `start: long = g()` is told about defaults and
    /// not about a `let` they never wrote.
    fold_subject: ?[]const u8 = null,
    /// The written construction whose container row a fold may append.
    /// Null for enum members and object-free field defaults.  A
    /// dependency temporarily installs its own construction, so a
    /// separately declared constant keeps its own identity even when
    /// another constant names it (docs/CONSTANTS.md C5).
    fold_container_name: ?[]const u8 = null,
    fold_container_file: source_mod.FileId = source_mod.root_file,
    fold_container_origin: u32 = 0,
    /// True only while the elements of one container construction are
    /// folding.  A literal reached recursively is a nested constant
    /// container and is refused in this run (R-E).
    folding_container: bool = false,

    fn deinitScratch(self: *Analyzer) void {
        self.struct_decls.deinit(self.temporary);
        self.struct_shapes.deinit(self.temporary);
        self.struct_names.deinit(self.temporary);
        self.enum_decls.deinit(self.temporary);
        self.enum_names.deinit(self.temporary);
        self.variant_decls.deinit(self.temporary);
        self.variant_names.deinit(self.temporary);
        self.variant_shapes.deinit(self.temporary);
        self.function_names.deinit(self.temporary);
        self.pool.deinit();
        self.constant_infos.deinit(self.temporary);
        self.constant_names.deinit(self.temporary);
    }

    /// Add one semantic diagnostic, honoring the report cap.  Every
    /// diagnostic in this stage goes through here.  Checking keeps
    /// running either way — callers already handle a failed check by
    /// unwinding the expression, not the walk — so what a program is
    /// accepted or rejected for never depends on how many errors came
    /// before it.
    pub fn fail(self: *Analyzer, code: []const u8, span: Span, comptime format: []const u8, arguments: anytype) Error!void {
        if (self.reported > max_diagnostics) return;
        if (self.reported == max_diagnostics) {
            self.reported += 1;
            try self.diagnostics.add(
                "luce.sema.limit",
                span,
                "too many semantic errors; only the first {d} are reported",
                .{max_diagnostics},
            );
            return;
        }
        self.reported += 1;
        try self.diagnostics.add(code, span, format, arguments);
    }

    fn run(self: *Analyzer) Error!?Analyzed {
        // Enum and union *names* first: a struct field, a parameter or
        // a constant's annotation may name one, and a name has to be
        // resolvable before any type is (docs/ENUMS.md, docs/UNION.md).
        // Enum member *values* are folded after the constant names are
        // registered, because `= base + 1` may name a constant; union
        // member *fields* are resolved after the struct names are,
        // because a payload may hold one.
        try self.collectTypeNames();
        try self.collectStructs();
        try self.settleVariantMembers();
        try self.settleTypeShapes();
        try self.registerConstants();
        try self.settleEnumMembers();
        try constants.foldAll(self);
        try self.settleFieldDefaults();
        try self.settleVariantDefaults();
        try self.collectFunctions();
        try self.inferReceiverWrites();
        try self.synthesizeShapes();
        if (self.diagnostics.hasErrors()) return null;

        var lowered: std.ArrayList(mir.build.Lowering) = .empty;
        defer lowered.deinit(self.arena);
        // **By index, because the list grows while it is walked.**  A
        // lambda becomes a top-level function the moment its landing
        // site is checked (docs/FUNCTIONS.md D2), so lowering function
        // K can append function K+n — and that one is lowered in its
        // turn, by this loop, with no second pass and no fix-up.
        var at: usize = 0;
        while (at < self.functions.items.len) : (at += 1) {
            try lowered.append(self.arena, try self.lowerFunction(self.functions.items[at]));
        }
        if (self.diagnostics.hasErrors()) return null;

        const entry_index = self.function_names.get("main") orelse return null;

        return .{
            .structs = try self.structs.toOwnedSlice(self.arena),
            .heap_types = try self.heap_types.toOwnedSlice(self.arena),
            .signatures = try self.signatures.toOwnedSlice(self.arena),
            .enums = try self.enums.toOwnedSlice(self.arena),
            .variants = try self.variants.toOwnedSlice(self.arena),
            .functions = try lowered.toOwnedSlice(self.arena),
            .constants = try self.pool.items.toOwnedSlice(self.arena),
            .container_constants = try self.pool.containers.toOwnedSlice(self.arena),
            .entry_function = entry_index,
        };
    }

    // Declarations ---------------------------------------------------------

    // -- names, types, and the heap shapes behind them --------------------

    /// A module-qualified declaration name: "geo" + "Point" ->
    /// "geo.Point"; the root module ("") qualifies to the name itself.
    pub fn qualify(self: *Analyzer, prefix: []const u8, name: []const u8) Error![]const u8 {
        if (prefix.len == 0) return name;
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ prefix, name });
    }

    /// The name a refusal calls `module` — the namespace a program
    /// writes in front of the dot.  Only ever read for a declaring
    /// module in a cross-module refusal, and the root module cannot be
    /// imported, so the answer is never empty where it is used.
    pub fn moduleName(self: *const Analyzer, module: usize) []const u8 {
        return self.modules[module].binding;
    }

    /// The declared key a written cross-module reference resolves to:
    /// the imported module's own qualification prefix, plus the member
    /// path.  `written` is "geo.Point" or "geo.Text.width", and the
    /// head should already be known to bind an import of `module`
    /// (`importsModule`); anything else answers the written text
    /// unchanged.  For a module of the program's own root the key *is*
    /// the written text; a package module's key carries its root
    /// (docs/PACKAGES.md D7), which is how the same written text in
    /// two packages names two different declarations.  Arena-allocated
    /// when it differs from `written`.
    pub fn importedName(self: *Analyzer, module: usize, written: []const u8) Error![]const u8 {
        const dot = std.mem.indexOfScalar(u8, written, '.') orelse return written;
        const head = written[0..dot];
        const prefix = self.importedPrefix(module, head) orelse return written;
        if (std.mem.eql(u8, prefix, head)) return written;
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ prefix, written[dot + 1 ..] });
    }

    /// The qualification prefix of whatever `module` imports bound as
    /// `head`, or null when nothing is.  Resolution's claims are the
    /// memory read back here: the import's spelled name, asked in the
    /// importing file's own namespace, names the file, and the file
    /// names its module — which is what tells two same-named package
    /// internals apart when two modules each bind a `util`.
    pub fn importedPrefix(self: *const Analyzer, module: usize, head: []const u8) ?[]const u8 {
        for (self.modules[module].tree.imports) |imported| {
            if (!std.mem.eql(u8, imported.binding, head)) continue;
            // The library keys by its binding wherever it is imported
            // from, so the written head is already the prefix.
            if (imported.origin == .standard) return head;
            const namespace = self.diagnostics.sources.rootOf(self.modules[module].file);
            const file = self.diagnostics.sources.claim(namespace, imported.name) orelse return head;
            for (self.modules) |candidate| {
                if (candidate.file == file) return candidate.prefix;
            }
            return head;
        }
        return null;
    }

    /// The visibility rule entire (docs/VISIBILITY.md D1): a
    /// declaration of `owner` marked `visibility` is reachable from
    /// `from` unless it says private and `from` is another file.
    /// Within one file the bit is never consulted.
    pub fn reachable(owner: usize, visibility: ast.Visibility, from: usize) bool {
        return visibility != .private or owner == from;
    }

    /// Where a D4 sentence says the mark lives: the module's name, or
    /// "this file" for the root — which nothing can import, but whose
    /// own surface checks still run and still land on the marker's
    /// author.
    pub fn markedIn(self: *const Analyzer, module: usize) []const u8 {
        const binding = self.modules[module].binding;
        return if (binding.len == 0) "this file" else binding;
    }

    /// The name of the private declaration `of` mentions, if any —
    /// transitively through containers and optionals, because a
    /// `list(Inner)` in a public signature publishes Inner exactly as a
    /// bare `Inner` would (docs/VISIBILITY.md §2).  It does not look
    /// *into* a struct's fields: mentioning a public struct that
    /// privately holds hidden types publishes nothing, and those fields
    /// were checked at their own declaration.
    ///
    /// The **name** rather than an index, because two kinds of
    /// declaration can be the hidden one now — a struct and an enum —
    /// and every caller wants the same one thing to put in a sentence.
    pub fn privateMentioned(self: *const Analyzer, of: Type) ?[]const u8 {
        return switch (of) {
            .strukt => |index| if (self.struct_decls.items[index].declaration.visibility == .private)
                self.struct_decls.items[index].declaration.name
            else
                null,
            .enumeration => |reference| if (self.enum_decls.items[reference.index].declaration.visibility == .private)
                self.enum_decls.items[reference.index].declaration.name
            else
                null,
            .variant => |index| if (self.variant_decls.items[index].declaration.visibility == .private)
                self.variant_decls.items[index].declaration.name
            else
                null,
            .heap => |index| switch (self.heap_types.items[index]) {
                .list => |element| self.privateMentioned(element),
                // A map key is long or string, never a struct.
                .map => |pair| self.privateMentioned(pair.value),
                .array => |shape| self.privateMentioned(shape.element),
                .builder, .file => null,
                .task => |work| self.privateMentioned(work.result),
            },
            // A function type publishes every type in its signature.
            // `func(Inner) -> long` on a public declaration is no less
            // an exposure of private `Inner` than `list(Inner)` is;
            // walking only the outer tag left a quiet second door
            // through VISIBILITY.md D4.
            .function => |index| blk: {
                const signature = self.signatures.items[index];
                for (signature.parameters) |parameter| {
                    if (self.privateMentioned(parameter.value_type)) |hidden| break :blk hidden;
                }
                break :blk self.privateMentioned(signature.result);
            },
            .optional => |payload| self.privateMentioned(payload.asType()),
            else => null,
        };
    }

    /// True when `module` imports something *bound* as `name` — the
    /// namespace a call site writes, which is an import's last segment
    /// unless an `as` chose otherwise.
    pub fn importsModule(self: *const Analyzer, module: usize, name: []const u8) bool {
        for (self.modules[module].tree.imports) |imported| {
            if (std.mem.eql(u8, imported.binding, name)) return true;
        }
        return false;
    }

    /// True only for the embedded-library spelling `import std.NAME`.
    /// A sibling `import NAME` binds the same namespace at use sites,
    /// but cannot satisfy a gate that promises compiler-owned source.
    pub fn importsStandardModule(self: *const Analyzer, module: usize, name: []const u8) bool {
        for (self.modules[module].tree.imports) |imported| {
            if (imported.origin == .standard and std.mem.eql(u8, imported.name, name)) return true;
        }
        return false;
    }

    /// True when `module` is the embedded `std.NAME` itself, rather
    /// than a sibling file that happens to be named NAME.
    pub fn isStandardModule(self: *const Analyzer, module: usize, name: []const u8) bool {
        if (!std.mem.eql(u8, self.modules[module].binding, name)) return false;
        const source = self.diagnostics.sources.at(self.modules[module].file) orelse return false;
        return source.kind == .standard;
    }

    /// The import that would make `name` reachable, spelled the way
    /// the author has to write it: `std.math` for the library, `geo`
    /// for a file beside the program, `geo.shapes` for one in a
    /// project subfolder — with the alias appended when the module is
    /// bound under a name that is not its own last segment, because
    /// any other spelling of the import would bind something else.
    ///
    /// A module already in the program answers for itself — a
    /// sibling `math.luc` that another file imports is reached with
    /// `import math`, even though `std.math` exists too.  Only when
    /// nothing is loaded under the name does the library get to
    /// claim it.
    pub fn importSpelling(self: *Analyzer, name: []const u8) Error![]const u8 {
        for (self.modules) |module| {
            if (!std.mem.eql(u8, module.binding, name)) continue;
            const spelled = self.diagnostics.sources.at(module.file).?.name;
            const is_tail = spelled.len >= name.len and tail: {
                const at = spelled.len - name.len;
                break :tail std.mem.eql(u8, spelled[at..], name) and
                    (at == 0 or spelled[at - 1] == '.');
            };
            if (is_tail) return spelled;
            return std.fmt.allocPrint(self.arena, "{s} as {s}", .{ spelled, name });
        }
        if (!source_mod.isStandard(name)) return name;
        return self.qualify(source_mod.standard_namespace, name);
    }

    /// Resolve a written type, including a trailing `?`.
    ///
    /// `T?` is a type; `T??` has no representation to resolve into and
    /// stage 3 refuses it before this ever sees it.
    pub fn resolveType(self: *Analyzer, module: usize, written: ast.TypeName) Error!?Type {
        const base = (try self.resolveBase(module, written)) orelse return null;
        if (!written.optional) return base;
        if (base == .function) {
            try self.fail(
                "luce.sema.type",
                written.span,
                "a function value has no absent form yet: drop the '?' [FUNCTIONS.md]",
                .{},
            );
            return null;
        }
        return Type.optionalOf(base) orelse {
            try self.fail("luce.sema.type", written.span, "None? is not a type: there is nothing there to be absent", .{});
            return null;
        };
    }

    /// The `?` that a container element may not carry.  Refused in v1
    /// (docs/FAILURE.md): `[1, none, none, 2]` would need a
    /// representation for an absent element that the containers do not
    /// have, and PEP 505's objection to that gap is the one that
    /// transfers.
    pub fn refuseOptionalPart(
        self: *Analyzer,
        part: Type,
        written: ast.TypeName,
        role: []const u8,
    ) Error!bool {
        if (part != .optional) return false;
        try self.fail("luce.sema.type", written.span, "a {s} cannot be optional: write {s} and keep the absence in a name of its own", .{
            role,
            try self.typeName(part.held().?),
        });
        return true;
    }

    fn resolveBase(self: *Analyzer, module: usize, written: ast.TypeName) Error!?Type {
        // Before anything else, including the arity checks: a name the
        // language used to answer to is answered by name, whatever
        // shape it was written in.  `List(long)` must be told that
        // `List` is `list` and not that it "takes no type arguments",
        // which is a sentence about a struct nobody declared.
        if (types.retiredSpelling(written.name)) |now| {
            try self.fail(
                "luce.sema.type",
                written.span,
                "the builtin types are lowercase: {s} is written {s}",
                .{ written.name, now },
            );
            return null;
        }
        // `func(T, ...) -> R`.  Not in the builtin table because it is
        // not a name a program could have written for something else:
        // `func` is a keyword, so this shape reaches here from the
        // parser and from nowhere a reader could collide with.
        if (written.result != null or std.mem.eql(u8, written.name, "func")) {
            return self.resolveSignature(module, written);
        }
        if (types.builtinNamed(written.name)) |builtin| switch (builtin) {
            .boolean, .byte, .short, .int, .long, .half, .float, .double, .string => {
                if (written.arguments.len != 0 or written.wildcards != 0) {
                    try self.fail("luce.sema.type", written.span, "{s} takes no type arguments", .{written.name});
                    return null;
                }
                return switch (builtin) {
                    .boolean => .boolean,
                    .byte => .byte,
                    .short => .short,
                    .int => .int,
                    .long => .long,
                    .half => .half,
                    .float => .float,
                    .double => .double,
                    .string => .string,
                    .list, .map, .array, .builder, .file, .task => unreachable, // answered by the outer switch
                };
            },
            .list => {
                if (written.arguments.len != 1 or written.wildcards != 0) {
                    try self.fail("luce.sema.type", written.span, "list takes one element type: list(long)", .{});
                    return null;
                }
                const element = (try self.resolveType(module, written.arguments[0])) orelse return null;
                if (try self.refuseOptionalPart(element, written.arguments[0], "list element")) return null;
                if (try self.refuseFunctionPart(element, written.arguments[0].span, "list element")) return null;
                return try self.internHeapType(.{ .list = element });
            },
            .map => {
                if (written.arguments.len != 2 or written.wildcards != 0) {
                    try self.fail("luce.sema.type", written.span, "map takes key and value types: map(string, long)", .{});
                    return null;
                }
                const key = (try self.resolveType(module, written.arguments[0])) orelse return null;
                if (key != .long and key != .string) {
                    // An enum is a value at a width like any other, and
                    // the width a map may key by is `long` — the same
                    // rule that refuses `map(int, V)`, met by a type
                    // that has a name for its number.  So the sentence
                    // names the number rather than stopping at the
                    // rule (docs/ENUMS.md, As built).
                    if (key == .enumeration) {
                        try self.fail(
                            "luce.sema.type",
                            written.arguments[0].span,
                            "map keys are long or string; key by long(m) and keep {s} in the value, or use a list indexed by int(m)",
                            .{try self.typeName(key)},
                        );
                        return null;
                    }
                    // A union has no number and no key form at all
                    // (docs/UNION.md D15): the sentence offers the one
                    // move that exists — keep it in the value.
                    if (key == .variant) {
                        try self.fail(
                            "luce.sema.type",
                            written.arguments[0].span,
                            "map keys are long or string; a union has no key form — keep {s} in the value and key by what identifies it",
                            .{try self.typeName(key)},
                        );
                        return null;
                    }
                    try self.fail("luce.sema.type", written.arguments[0].span, "map keys are long or string", .{});
                    return null;
                }
                const value = (try self.resolveType(module, written.arguments[1])) orelse return null;
                if (try self.refuseOptionalPart(value, written.arguments[1], "map value")) return null;
                if (try self.refuseFunctionPart(value, written.arguments[1].span, "map value")) return null;
                return try self.internHeapType(.{ .map = .{ .key = key, .value = value } });
            },
            .array => {
                if (written.arguments.len != 1 or written.wildcards == 0 or written.wildcards > 4) {
                    try self.fail(
                        "luce.sema.type",
                        written.span,
                        "array spells element and shape: array(long, _) up to array(long, _, _, _, _)",
                        .{},
                    );
                    return null;
                }
                const element = (try self.resolveType(module, written.arguments[0])) orelse return null;
                if (try self.refuseOptionalPart(element, written.arguments[0], "array element")) return null;
                if (try self.refuseFunctionPart(element, written.arguments[0].span, "array element")) return null;
                return try self.internHeapType(.{ .array = .{ .element = element, .rank = written.wildcards } });
            },
            .builder => {
                if (written.arguments.len != 0 or written.wildcards != 0) {
                    try self.fail("luce.sema.type", written.span, "builder takes no type arguments", .{});
                    return null;
                }
                return try self.internHeapType(.builder);
            },
            .file => {
                if (written.arguments.len != 0 or written.wildcards != 0) {
                    try self.fail("luce.sema.type", written.span, "file takes no type arguments", .{});
                    return null;
                }
                return try self.internHeapType(.file);
            },
            // `task(...)` holds a **return shape**, written exactly as
            // it would be after `->`: `task(double)`, `task(double!)`,
            // `task(!)`, and a bare `task` for a worker that answers
            // nothing and cannot fail (docs/THREADS.md D3).  The `!` is
            // the spawned function's own attribute travelling with the
            // call the task carries — `types.Type` is untouched by it,
            // exactly as `Function.fallible` leaves it untouched.
            .task => {
                if (written.wildcards != 0 or written.arguments.len > 1) {
                    try self.fail("luce.sema.type", written.span, "task holds one answer: task(T), task(T!), task(!), or task", .{});
                    return null;
                }
                var answered: Type = .none;
                if (written.arguments.len == 1) {
                    answered = (try self.resolveType(module, written.arguments[0])) orelse return null;
                }
                return try self.internHeapType(.{
                    .task = .{ .result = answered, .fallible = written.fallible },
                });
            },
        };
        if (written.arguments.len != 0 or written.wildcards != 0) {
            try self.fail("luce.sema.type", written.span, "{s} takes no type arguments", .{written.name});
            return null;
        }
        // module.Struct reaches an imported type; a bare name is local
        // to the module it appears in.
        if (std.mem.indexOfScalar(u8, written.name, '.')) |dot| {
            const head = written.name[0..dot];
            // `let c: Shape.circle` — a union member is not a type
            // (docs/UNION.md D3, docs/RETURNS.md's reason): every
            // member is one of the union, and the union is the type.
            if (self.variant_names.get(try self.qualify(self.modules[module].prefix, head))) |index| {
                try self.fail(
                    "luce.sema.union",
                    written.span,
                    "a member is not a type: every member of {s} is a {s}, so write {s}",
                    .{ self.variant_decls.items[index].declaration.name, self.variant_decls.items[index].declaration.name, head },
                );
                return null;
            }
            if (!self.importsModule(module, head)) {
                try self.fail("luce.sema.import", written.span, "unknown module {s}; import {s} to use its types", .{ head, try self.importSpelling(head) });
                return null;
            }
            const key = try self.importedName(module, written.name);
            if (self.struct_names.get(key)) |index| {
                // Private is not unknown (VISIBILITY.md D2): the name
                // exists and is withheld, and the sentence says which.
                const info = self.struct_decls.items[index];
                if (!reachable(info.module, info.declaration.visibility, module)) {
                    try self.fail(
                        "luce.sema.private",
                        written.span,
                        "{s} is private to {s}",
                        .{ info.declaration.name, self.moduleName(info.module) },
                    );
                    return null;
                }
                return .{ .strukt = index };
            }
            if (self.enum_names.get(key)) |index| {
                const info = self.enum_decls.items[index];
                if (!reachable(info.module, info.declaration.visibility, module)) {
                    try self.fail(
                        "luce.sema.private",
                        written.span,
                        "{s} is private to {s}",
                        .{ info.declaration.name, self.moduleName(info.module) },
                    );
                    return null;
                }
                return self.enumType(index);
            }
            if (self.variant_names.get(key)) |index| {
                const info = self.variant_decls.items[index];
                if (!reachable(info.module, info.declaration.visibility, module)) {
                    try self.fail(
                        "luce.sema.private",
                        written.span,
                        "{s} is private to {s}",
                        .{ info.declaration.name, self.moduleName(info.module) },
                    );
                    return null;
                }
                return .{ .variant = index };
            }
            try self.failUnknownType(module, written);
            return null;
        }
        const local = try self.qualify(self.modules[module].prefix, written.name);
        if (self.struct_names.get(local)) |index| return .{ .strukt = index };
        if (self.enum_names.get(local)) |index| return self.enumType(index);
        if (self.variant_names.get(local)) |index| return .{ .variant = index };
        try self.failUnknownType(module, written);
        return null;
    }

    /// `func(T, ...) -> R` — the written function type, interned
    /// (docs/FUNCTIONS.md S2).
    ///
    /// **Where a function type may stand is a short list in this run**:
    /// a parameter and a `let`.  A container element and a struct field
    /// are refused by the two callers that ask for one, because each is
    /// a real question of its own — a struct carrying behaviour is
    /// dispatch — and neither is needed by the customers.  The sentence
    /// says "not yet", because that is what it is.
    fn resolveSignature(self: *Analyzer, module: usize, written: ast.TypeName) Error!?Type {
        const parameters = try self.arena.alloc(types.Signature.Parameter, written.arguments.len);
        for (written.arguments, parameters) |part, *parameter| {
            const resolved = (try self.resolveType(module, part)) orelse return null;
            if (part.gives and !self.carriesObjects(resolved)) {
                try self.fail(
                    "luce.sema.own",
                    part.span,
                    "give applies to containers and resources (list, map, array, builder, file, task) and structs that carry them, not values [OWNERSHIP.md S32]",
                    .{},
                );
                return null;
            }
            parameter.* = .{ .value_type = resolved, .gives = part.gives };
        }
        var result: Type = .none;
        if (written.result) |answered| {
            result = (try self.resolveType(module, answered.*)) orelse return null;
        }
        return try self.internSignature(.{ .parameters = parameters, .result = result });
    }

    /// The "not yet" a function type is told where it may not stand.
    /// One sentence, said by every position that defers it, so a reader
    /// meets the same words wherever they meet the wall.
    pub fn refuseFunctionPart(
        self: *Analyzer,
        part: Type,
        span: Span,
        role: []const u8,
    ) Error!bool {
        if (part != .function) return false;
        try self.fail(
            "luce.sema.type",
            span,
            "a {s} cannot be a function yet: a function type stands on a parameter or a let [FUNCTIONS.md]",
            .{role},
        );
        return true;
    }

    /// Report a written type name that names nothing, offering the
    /// closest of the builtin types and the structs this module can
    /// see.  A misremembered `Str` or `Bolean` is the commonest of all
    /// type errors and the cheapest to answer well.
    fn failUnknownType(self: *Analyzer, module: usize, written: ast.TypeName) Error!void {
        // A name the language used to answer to gets told what it is
        // called now, by name.  Edit distance cannot find `long` from
        // `Int`, and a reader whose only mistake is remembering an
        // older spelling is owed the new one rather than "unknown
        // type" (docs/TYPES.md D8).
        if (types.retiredSpelling(written.name)) |now| {
            try self.fail(
                "luce.sema.type",
                written.span,
                "the builtin types are lowercase: {s} is written {s}",
                .{ written.name, now },
            );
            return;
        }
        const builtin_types = types.builtin_names;
        const prefix = self.modules[module].prefix;
        var suggestion = helpers.Suggestion.init(written.name);
        suggestion.offerAll(&builtin_types);
        for ([_]*const std.StringHashMapUnmanaged(u32){ &self.struct_names, &self.enum_names, &self.variant_names }) |declared| {
            var keys = declared.keyIterator();
            while (keys.next()) |key| {
                if (prefix.len == 0) {
                    suggestion.offer(key.*);
                } else if (key.len > prefix.len + 1 and
                    std.mem.startsWith(u8, key.*, prefix) and key.*[prefix.len] == '.')
                {
                    suggestion.offer(key.*[prefix.len + 1 ..]);
                }
            }
        }
        if (suggestion.best()) |closest| {
            try self.fail("luce.sema.type", written.span, "unknown type {s}; did you mean {s}?", .{ written.name, closest });
            return;
        }
        try self.fail("luce.sema.type", written.span, "unknown type {s}", .{written.name});
    }

    /// Heap types are interned: one index per distinct shape, so type
    /// equality stays an index comparison.
    pub fn internHeapType(self: *Analyzer, descriptor: types.HeapType) Error!Type {
        for (self.heap_types.items, 0..) |existing, index| {
            if (existing.eql(descriptor)) return .{ .heap = @intCast(index) };
        }
        try self.heap_types.append(self.arena, descriptor);
        return .{ .heap = @intCast(self.heap_types.items.len - 1) };
    }

    /// Intern one function signature and answer the type that names it.
    pub fn internSignature(self: *Analyzer, signature: types.Signature) Error!Type {
        for (self.signatures.items, 0..) |existing, index| {
            if (existing.eql(signature)) return .{ .function = @intCast(index) };
        }
        try self.signatures.append(self.arena, signature);
        return .{ .function = @intCast(self.signatures.items.len - 1) };
    }

    pub fn signatureOf(self: *const Analyzer, of: Type) ?types.Signature {
        if (of != .function) return null;
        return self.signatures.items[of.function];
    }

    pub fn heapOf(self: *const Analyzer, of: Type) ?types.HeapType {
        if (of != .heap) return null;
        return self.heap_types.items[of.heap];
    }

    /// True for types the ownership rules apply to: every heap-backed
    /// object, including file and task resources, and structs
    /// transitively containing one (S27's "object-carrying").  The
    /// legacy name says "objects", but it is the broad ownership
    /// predicate, not a list/map/array/builder-only test.
    /// An array read: `collectStructs` settles every struct's shape
    /// once the layouts are known, and struct cycles are rejected
    /// before that.
    pub fn carriesObjects(self: *const Analyzer, of: Type) bool {
        return switch (of) {
            .heap => true,
            .strukt => |layout_index| self.struct_shapes.items[layout_index].carries,
            // The OR over the members' fields (docs/UNION.md D9): the
            // predicate is static and type-level, so `Json` carries
            // objects unconditionally and `Json.number` pays the verb
            // anyway — S27's own rule, stated there and priced in the
            // memo.
            .variant => |index| self.variant_shapes.items[index].carries,
            // A `list(T)?` holding an object owns it exactly as the
            // unwrapped type would; holding `none` owns nothing (S43),
            // and every ownership walk already no-ops on absence.
            .optional => |payload| self.carriesObjects(payload.asType()),
            else => false,
        };
    }

    /// Whether `of` contains a scope-owned resource anywhere in its
    /// type graph.  Files and tasks are tied to the `Runtime` that made
    /// them: neither can be duplicated by `copy` or re-owned into a
    /// worker's separate runtime by `Runtime.copyFrom`.
    ///
    /// This is an iterative graph walk, not a recursive type query.  A
    /// source program may legitimately make `Node` contain
    /// `list(Node)`: the container makes the value's size finite, but it
    /// also makes the type graph cyclic.  The two visited tables keep
    /// that cycle, and shared subgraphs, linear in the number of layouts
    /// and interned heap shapes rather than in the number of paths.
    pub fn carriesResource(self: *const Analyzer, of: Type) Error!bool {
        const seen_structs = try self.temporary.alloc(bool, self.structs.items.len);
        defer self.temporary.free(seen_structs);
        @memset(seen_structs, false);

        const seen_heaps = try self.temporary.alloc(bool, self.heap_types.items.len);
        defer self.temporary.free(seen_heaps);
        @memset(seen_heaps, false);

        const seen_variants = try self.temporary.alloc(bool, self.variants.items.len);
        defer self.temporary.free(seen_variants);
        @memset(seen_variants, false);

        var pending: std.ArrayList(Type) = .empty;
        defer pending.deinit(self.temporary);
        try pending.append(self.temporary, of);

        while (pending.items.len != 0) {
            const current = pending.pop().?;
            switch (current) {
                .optional => |payload| try pending.append(self.temporary, payload.asType()),
                .strukt => |layout| {
                    if (seen_structs[layout]) continue;
                    seen_structs[layout] = true;
                    for (self.structs.items[layout].fields) |field| {
                        try pending.append(self.temporary, field.field_type);
                    }
                },
                .heap => |index| {
                    if (seen_heaps[index]) continue;
                    seen_heaps[index] = true;
                    switch (self.heap_types.items[index]) {
                        .list => |element| try pending.append(self.temporary, element),
                        .map => |pair| {
                            try pending.append(self.temporary, pair.key);
                            try pending.append(self.temporary, pair.value);
                        },
                        .array => |shape| try pending.append(self.temporary, shape.element),
                        .builder => {},
                        .file, .task => return true,
                    }
                },
                .variant => |index| {
                    if (seen_variants[index]) continue;
                    seen_variants[index] = true;
                    for (self.variants.items[index].members) |member| {
                        for (member.fields) |field| {
                            try pending.append(self.temporary, field.field_type);
                        }
                    }
                },
                .none,
                .boolean,
                .byte,
                .short,
                .int,
                .long,
                .half,
                .float,
                .double,
                .string,
                .enumeration,
                .function,
                => {},
            }
        }
        return false;
    }

    /// True for types that carry *storage* — a string's bytes, a
    /// struct's field run — as opposed to objects (docs/STRINGS.md).
    ///
    /// Deliberately not `carriesObjects`, and deliberately not wired to
    /// it.  This predicate drives release emission and nothing else:
    /// widening `carriesObjects` to Strings would make `xs.append(name)`
    /// demand `give name` under S21, which is a language change.  A
    /// string takes no verbs (S32) and still gets reclaimed, which is
    /// the whole point.
    pub fn ownsStorage(self: *const Analyzer, of: Type) bool {
        return switch (of) {
            // A struct owns its field run whatever is in it, so this
            // needs no shape lookup — an all-long struct still has a
            // run to give back.  A union value is a run whose slot 0
            // is the tag, and owns it exactly the same way
            // (docs/UNION.md D8, D9).
            .string, .strukt, .variant => true,
            .optional => |payload| self.ownsStorage(payload.asType()),
            else => false,
        };
    }

    /// How many values a type flattens to: one, unless it is a struct
    /// that nests others.
    ///
    /// **An optional answers one whatever its payload is, and that is
    /// deliberate.**  The two arms look inconsistent — `Big` flattens
    /// and `Big?` does not, for the same data — and the difference is
    /// the point: this counts what a value of the type
    /// *unconditionally* costs, and an optional's payload is not
    /// unconditional.  `zeroOf` is the proof, because it is what the
    /// count predicts: it recurses through a struct field emitting an
    /// instruction per leaf, and stops dead at an optional one, whose
    /// zero is a single `none`.  Measured, with a struct of two struct
    /// fields per level: twelve levels is 12,341 MIR instructions and
    /// sixty levels of the optional spelling is 201.
    ///
    /// Flattening optionals too is not available even in principle:
    /// the shape walk closes a layout only after the layouts it
    /// contains, and `struct Node: next: Node?` has no such order.  It
    /// would have to be reported as a cycle — destroying the fix the
    /// cycle diagnostic itself prescribes, and with it the only way to
    /// write a recursive structure.  Flattening *neither* was the other
    /// candidate and is worse than wrong: with `.strukt` answering one,
    /// the bound never fires, and ninety lines of source took 2.76 GB
    /// and 1.6 s to check.
    fn valueCount(self: *const Analyzer, of: Type) u32 {
        return switch (of) {
            .strukt => |layout_index| self.struct_shapes.items[layout_index].values,
            .variant => |index| self.variant_shapes.items[index].values,
            else => 1,
        };
    }

    // -- pass one: enums and unions, names then contents -------------------

    /// Register every declared enum's and union's name, in source
    /// order per module, so a duplicate between the two kinds reports
    /// at whichever stands second in the file — the same promise the
    /// struct-above check keeps one kind at a time.
    fn collectTypeNames(self: *Analyzer) Error!void {
        for (self.modules, 0..) |module, module_index| {
            self.diagnostics.scope = module.file;
            var next_enum: usize = 0;
            var next_union: usize = 0;
            while (next_enum < module.tree.enums.len or next_union < module.tree.unions.len) {
                const take_enum = next_union >= module.tree.unions.len or
                    (next_enum < module.tree.enums.len and
                        module.tree.enums[next_enum].name_span.start <
                            module.tree.unions[next_union].name_span.start);
                if (take_enum) {
                    try self.collectEnumName(module, module_index, &module.tree.enums[next_enum]);
                    next_enum += 1;
                } else {
                    try self.collectUnionName(module, module_index, &module.tree.unions[next_union]);
                    next_union += 1;
                }
            }
        }
        self.diagnostics.scope = source_mod.root_file;
    }

    /// Register one declared enum's name and backing width
    /// (docs/ENUMS.md D1, D2).  The members are collected here too,
    /// with their names and their *positions*; the values are folded by
    /// `settleEnumMembers` below, once every name in the program
    /// exists.
    fn collectEnumName(
        self: *Analyzer,
        module: ModuleTree,
        module_index: usize,
        declaration: *const ast.EnumDecl,
    ) Error!void {
        if (isReserved(declaration.name)) {
            try self.fail("luce.sema.reserved", declaration.name_span, "{s} is a reserved name", .{declaration.name});
            return;
        }
        if (types.builtinNamed(declaration.name) != null) {
            try self.fail(
                "luce.sema.reserved",
                declaration.name_span,
                "{s} is a builtin type; an enum of your own takes a name of its own",
                .{declaration.name},
            );
            return;
        }
        const qualified = try self.qualify(module.prefix, declaration.name);
        if (try self.firstDeclarationOf(qualified)) |where| {
            try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                declaration.name,
                where,
            });
            return;
        }
        // **Whichever was written first is the first.**  Enums are
        // collected before structs — a struct field may name one — so
        // a struct of the same name is still invisible here; the one
        // this file *reads* first is decided by where the two stand,
        // not by which table filled first.  A struct above this enum
        // reports here; a struct below it lets the enum register and
        // reports there.
        if (structDeclaredAbove(module.tree.*, declaration.name, declaration.name_span)) |first| {
            try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                declaration.name,
                try self.declaredAt(module.file, first.name_span),
            });
            return;
        }
        // The width, before the members: it is what says which of them
        // fit, and the default is `int` (D2).
        var backing: types.Type.EnumRef.Backing = .int;
        if (declaration.backing) |written| {
            const resolved = (try self.resolveType(module_index, written)) orelse return;
            backing = types.Type.EnumRef.Backing.of(resolved) orelse {
                try self.fail(
                    "luce.sema.enum",
                    written.span,
                    "an enum is stored at an integer width: byte, short, int, or long — not {s}",
                    .{try self.typeName(resolved)},
                );
                return;
            };
        }
        if (declaration.members.len == 0) {
            try self.fail(
                "luce.sema.enum",
                declaration.span,
                "enum {s} names no members; an enum is the set of names it declares",
                .{declaration.name},
            );
            return;
        }
        var members: std.ArrayList(types.EnumMember) = .empty;
        defer members.deinit(self.arena);
        for (declaration.members) |member| {
            if (isReserved(member.name)) {
                try self.fail("luce.sema.reserved", member.name_span, "{s} is a reserved name", .{member.name});
                continue;
            }
            var duplicate = false;
            for (members.items) |existing| {
                if (std.mem.eql(u8, existing.name, member.name)) duplicate = true;
            }
            if (duplicate) {
                try self.fail(
                    "luce.sema.duplicate",
                    member.name_span,
                    "duplicate member {s} of enum {s}",
                    .{ member.name, declaration.name },
                );
                continue;
            }
            // A function of the enum may not wear a member's name:
            // `Method.stored` would mean two things, and the
            // head-names-a-declaration path answers one.
            for (declaration.functions) |function| {
                if (!std.mem.eql(u8, function.name, member.name)) continue;
                try self.fail(
                    "luce.sema.duplicate",
                    function.span,
                    "enum {s} already has member {s}",
                    .{ declaration.name, function.name },
                );
            }
            try members.append(self.arena, .{ .name = try self.arena.dupe(u8, member.name), .value = 0 });
        }
        if (members.items.len == 0) return; // every member was refused
        const index: u32 = @intCast(self.enums.items.len);
        try self.enum_names.put(self.temporary, qualified, index);
        try self.enum_decls.append(self.temporary, .{
            .declaration = declaration,
            .module = module_index,
        });
        try self.enums.append(self.arena, .{
            .name = try self.arena.dupe(u8, qualified),
            .backing = backing,
            .members = try members.toOwnedSlice(self.arena),
        });
    }

    /// Register one declared union's name and its members' names
    /// (docs/UNION.md D1).  The member *field types* are resolved by
    /// `settleVariantMembers` below, once the struct names exist —
    /// a payload may hold one, and a struct field may hold a union.
    fn collectUnionName(
        self: *Analyzer,
        module: ModuleTree,
        module_index: usize,
        declaration: *const ast.UnionDecl,
    ) Error!void {
        if (isReserved(declaration.name)) {
            try self.fail("luce.sema.reserved", declaration.name_span, "{s} is a reserved name", .{declaration.name});
            return;
        }
        if (types.builtinNamed(declaration.name) != null) {
            try self.fail(
                "luce.sema.reserved",
                declaration.name_span,
                "{s} is a builtin type; a union of your own takes a name of its own",
                .{declaration.name},
            );
            return;
        }
        const qualified = try self.qualify(module.prefix, declaration.name);
        if (try self.firstDeclarationOf(qualified)) |where| {
            try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                declaration.name,
                where,
            });
            return;
        }
        if (structDeclaredAbove(module.tree.*, declaration.name, declaration.name_span)) |first| {
            try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                declaration.name,
                try self.declaredAt(module.file, first.name_span),
            });
            return;
        }
        if (declaration.members.len == 0) {
            try self.fail(
                "luce.sema.union",
                declaration.span,
                "union {s} names no members; a union is the set of members it declares",
                .{declaration.name},
            );
            return;
        }
        // **At least one member must carry a payload** (D2): a union
        // of bare members is an enum — cheaper in every way, with a
        // backing width, `int(m)`, `{s}(n)` and no allocation.
        var carries_payload = false;
        for (declaration.members) |member| {
            if (member.fields.len != 0) carries_payload = true;
        }
        if (!carries_payload) {
            try self.fail(
                "luce.sema.union",
                declaration.span,
                "no member of union {s} carries a payload; a set of bare names is an enum — write enum {s}:",
                .{ declaration.name, declaration.name },
            );
            return;
        }
        var members: std.ArrayList(types.VariantMember) = .empty;
        defer members.deinit(self.arena);
        for (declaration.members) |member| {
            if (isReserved(member.name)) {
                try self.fail("luce.sema.reserved", member.name_span, "{s} is a reserved name", .{member.name});
                continue;
            }
            var duplicate = false;
            for (members.items) |existing| {
                if (std.mem.eql(u8, existing.name, member.name)) duplicate = true;
            }
            if (duplicate) {
                try self.fail(
                    "luce.sema.duplicate",
                    member.name_span,
                    "duplicate member {s} of union {s}",
                    .{ member.name, declaration.name },
                );
                continue;
            }
            // A function of the union may not wear a member's name:
            // `Shape.circle` would mean two things (D17).
            for (declaration.functions) |function| {
                if (!std.mem.eql(u8, function.name, member.name)) continue;
                try self.fail(
                    "luce.sema.duplicate",
                    function.span,
                    "union {s} already has member {s}",
                    .{ declaration.name, function.name },
                );
            }
            // Field slots are allocated now, in member order, and
            // typed by `settleVariantMembers`; a field refused there
            // keeps its slot so the member's arity stays the
            // declaration's.
            try members.append(self.arena, .{
                .name = try self.arena.dupe(u8, member.name),
                .fields = try self.arena.alloc(types.StructField, member.fields.len),
            });
        }
        if (members.items.len == 0) return; // every member was refused
        const index: u32 = @intCast(self.variants.items.len);
        try self.variant_names.put(self.temporary, qualified, index);
        try self.variant_decls.append(self.temporary, .{
            .declaration = declaration,
            .module = module_index,
        });
        try self.variants.append(self.arena, .{
            .name = try self.arena.dupe(u8, qualified),
            .members = try members.toOwnedSlice(self.arena),
        });
    }

    /// The struct of this module that takes `name` and stands above
    /// `span` in the file, or null.
    fn structDeclaredAbove(tree: ast.Program, name: []const u8, span: Span) ?*const ast.StructDecl {
        for (tree.structs) |*strukt| {
            if (!std.mem.eql(u8, strukt.name, name)) continue;
            if (strukt.name_span.start < span.start) return strukt;
        }
        return null;
    }

    /// Fold every member's value, in declaration order (D1): a written
    /// `= EXPRESSION` is folded by the constant folder, an unvalued
    /// member takes the one before it plus one, and an unvalued first
    /// member is 0 — the C rule, verbatim.  Two members with one value
    /// are refused by name, and a value the backing width cannot hold
    /// is refused by the sentence a literal already gets.
    fn settleEnumMembers(self: *Analyzer) Error!void {
        for (0..self.enum_decls.items.len) |index| {
            const info = self.enum_decls.items[index];
            self.diagnostics.scope = self.modules[info.module].file;
            const backing = self.enums.items[index].backing.asType();
            const bounds = backing.integerRange();
            var next: i128 = 0;
            // The declaration's members and the collected ones differ
            // where one was refused, so they are walked by name.
            for (info.declaration.members) |written| {
                const slot = self.enums.items[index].findMember(written.name) orelse continue;
                var value: i128 = next;
                if (written.value) |expression| {
                    // Folded at `long` rather than at the backing
                    // width, so a value the width cannot hold is
                    // refused by *this* stage's sentence — the one that
                    // names the enum's width and the fix for it —
                    // rather than by the literal's, which would talk
                    // about a place the reader never wrote.
                    const folded = (try constants.fold(self, info.module, expression, .long)) orelse continue;
                    if (folded.value != .long or !folded.value_type.isInteger()) {
                        try self.fail(
                            "luce.sema.enum",
                            expression.span(),
                            "a member's value is a constant integer; {s} is {s}",
                            .{ written.name, try self.typeName(folded.value_type) },
                        );
                        continue;
                    }
                    value = folded.value.long;
                }
                if (value < bounds.low or value > bounds.high) {
                    try self.fail(
                        "luce.sema.enum",
                        written.span,
                        "{s} = {d} does not fit {s}, which holds {d} to {d}; write the enum's width wider — enum {s}(long):",
                        .{
                            written.name,
                            value,
                            try self.typeName(backing),
                            bounds.low,
                            bounds.high,
                            info.declaration.name,
                        },
                    );
                    continue;
                }
                // An alias is a `let` if a program wants one: two names
                // for one number make `string(m)` a coin toss and
                // `match` a set of arms that cannot all be reached.
                for (self.enums.items[index].members[0..slot]) |earlier| {
                    if (earlier.value != @as(i64, @intCast(value))) continue;
                    try self.fail(
                        "luce.sema.enum",
                        written.span,
                        "{s} and {s} are both {d}; every member of an enum holds its own number, and a second name for one is a let",
                        .{ earlier.name, written.name, value },
                    );
                    break;
                }
                self.enums.items[index].members[slot].value = @intCast(value);
                next = value + 1;
            }
            self.enum_decls.items[index].settled = true;
        }
        self.diagnostics.scope = source_mod.root_file;
    }

    /// The enum a written name resolves to, with its width — the one
    /// place an `EnumRef` is built, so the width beside an index is
    /// always the width that index declares.
    pub fn enumType(self: *const Analyzer, index: u32) Type {
        return .{ .enumeration = .{ .index = index, .backing = self.enums.items[index].backing } };
    }

    // -- pass one: struct layouts -----------------------------------------

    fn collectStructs(self: *Analyzer) Error!void {
        // Imports first: bindings must be usable and free of
        // collisions — the binding, not the module's name, because the
        // binding is the word that has to coexist with declarations.
        for (self.modules, 0..) |module, module_index| {
            self.diagnostics.scope = module.file;
            for (module.tree.imports) |imported| {
                if (isReserved(imported.binding) or std.mem.eql(u8, imported.binding, "evaluate")) {
                    try self.fail("luce.sema.reserved", imported.span, "{s} is a reserved name", .{imported.binding});
                }
                for (module.tree.structs) |declaration| {
                    if (std.mem.eql(u8, declaration.name, imported.binding)) {
                        try self.fail("luce.sema.duplicate", imported.span, "import {s} collides with a struct of the same name", .{imported.binding});
                    }
                }
                for (module.tree.enums) |declaration| {
                    if (std.mem.eql(u8, declaration.name, imported.binding)) {
                        try self.fail("luce.sema.duplicate", imported.span, "import {s} collides with an enum of the same name", .{imported.binding});
                    }
                }
                for (module.tree.unions) |declaration| {
                    if (std.mem.eql(u8, declaration.name, imported.binding)) {
                        try self.fail("luce.sema.duplicate", imported.span, "import {s} collides with a union of the same name", .{imported.binding});
                    }
                }
            }
            _ = module_index;
        }

        // Names first so fields may reference structs in any order.
        for (self.modules, 0..) |module, module_index| {
            self.diagnostics.scope = module.file;
            for (module.tree.structs) |*declaration| {
                if (isReserved(declaration.name)) {
                    try self.fail("luce.sema.reserved", declaration.name_span, "{s} is a reserved name", .{declaration.name});
                    continue;
                }
                // A struct may not take a builtin type's name.  It is
                // refused here rather than shadowed silently, because
                // `resolveBase` answers first and the declaration
                // would be a type nothing could ever write down.
                if (types.builtinNamed(declaration.name) != null) {
                    try self.fail(
                        "luce.sema.reserved",
                        declaration.name_span,
                        "{s} is a builtin type; a struct of your own takes a name of its own",
                        .{declaration.name},
                    );
                    continue;
                }
                const qualified = try self.qualify(module.prefix, declaration.name);
                // Structs and enums share the type-name space: one
                // name, one declaration, whichever keyword wrote it.
                if (try self.firstDeclarationOf(qualified)) |where| {
                    try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                        declaration.name,
                        where,
                    });
                    continue;
                }
                const index: u32 = @intCast(self.structs.items.len);
                try self.struct_names.put(self.temporary, qualified, index);
                try self.struct_decls.append(self.temporary, .{
                    .declaration = declaration,
                    .module = module_index,
                });
                try self.structs.append(self.arena, .{
                    .name = try self.arena.dupe(u8, qualified),
                    .fields = &.{},
                });
            }
        }

        for (self.struct_decls.items) |info| {
            const declaration = info.declaration;
            self.diagnostics.scope = self.modules[info.module].file;
            const qualified = try self.qualify(self.modules[info.module].prefix, declaration.name);
            const index = self.struct_names.get(qualified) orelse continue;
            var fields: std.ArrayList(types.StructField) = .empty;
            defer fields.deinit(self.arena);
            var field_defaults: std.ArrayList(context.FieldDefault) = .empty;
            defer field_defaults.deinit(self.arena);
            var field_visibility: std.ArrayList(ast.Visibility) = .empty;
            defer field_visibility.deinit(self.arena);
            // The first field that declared a default, for D3's
            // sentence when a required one follows it — the same
            // trailing rule a parameter list keeps (docs/ARGS.md D8).
            var first_defaulted: ?[]const u8 = null;
            for (declaration.fields) |field| {
                if (field.default == null) {
                    if (first_defaulted) |earlier| {
                        try self.fail(
                            "luce.sema.struct",
                            field.span,
                            "{s} has a default, so {s} needs one too — the fields with defaults come last",
                            .{ earlier, field.name },
                        );
                        continue;
                    }
                } else if (first_defaulted == null) {
                    first_defaulted = field.name;
                }
                var duplicate = false;
                for (fields.items) |existing| {
                    if (std.mem.eql(u8, existing.name, field.name)) duplicate = true;
                }
                if (duplicate) {
                    try self.fail("luce.sema.duplicate", field.name_span, "duplicate field {s}; the first is{s}", .{
                        field.name,
                        try self.declaredAt(self.modules[info.module].file, self.fieldSpan(index, field.name)),
                    });
                    continue;
                }
                const field_type = (try self.resolveType(info.module, field.type_name)) orelse continue;
                // A struct that carries behaviour is dispatch, and
                // dispatch is a question of its own — deferred rather
                // than refused (docs/FUNCTIONS.md S2).
                if (try self.refuseFunctionPart(field_type, field.type_name.span, "struct field")) continue;
                // D4, for a field: a reachable field may not publish a
                // hidden type.  Only the author of the marks can trip
                // this — nothing is private until someone writes it —
                // and the refusal lands on the line that can be fixed.
                // The field is still collected: its type resolved, and
                // dropping it would turn one mistake into a cascade
                // about the struct that holds it.
                if (declaration.visibility != .private and field.visibility != .private) {
                    if (self.privateMentioned(field_type)) |hidden| {
                        try self.fail(
                            "luce.sema.private",
                            field.type_name.span,
                            "{s} of {s} is public and holds {s}, which is marked private in {s}; mark {s} private or remove the mark on {s}",
                            .{
                                field.name,
                                declaration.name,
                                hidden,
                                self.markedIn(info.module),
                                field.name,
                                hidden,
                            },
                        );
                    }
                }
                try fields.append(self.arena, .{
                    .name = try self.arena.dupe(u8, field.name),
                    .field_type = field_type,
                });
                try field_defaults.append(self.arena, .{ .expression = field.default });
                try field_visibility.append(self.arena, field.visibility);
            }
            for (declaration.functions) |function| {
                for (declaration.fields) |field| {
                    if (std.mem.eql(u8, function.name, field.name)) {
                        try self.fail(
                            "luce.sema.duplicate",
                            function.span,
                            "struct {s} already has field {s}",
                            .{ declaration.name, function.name },
                        );
                    }
                }
            }
            if (fields.items.len == 0 and declaration.functions.len == 0) {
                try self.fail("luce.sema.struct", declaration.span, "struct {s} has an empty body", .{declaration.name});
            }
            self.structs.items[index].fields = try fields.toOwnedSlice(self.arena);
            self.struct_decls.items[index].field_defaults = try field_defaults.toOwnedSlice(self.arena);
            self.struct_decls.items[index].field_visibility = try field_visibility.toOwnedSlice(self.arena);
        }

        self.diagnostics.scope = source_mod.root_file;
    }

    /// A struct or union containing itself (directly or through
    /// another) would have no finite value; and what every one carries
    /// and costs is settled in the same walk (docs/UNION.md D12 —
    /// unions join the same graph as structs, every member counted).
    /// Runs after `settleVariantMembers`, because the graph's edges
    /// are the resolved field types.
    fn settleTypeShapes(self: *Analyzer) Error!void {
        const cyclic = try self.temporary.alloc(bool, self.structs.items.len + self.variants.items.len);
        defer self.temporary.free(cyclic);
        @memset(cyclic, false);
        try self.settleStructGraph(cyclic);
        try self.reportStructCycles(cyclic);

        for (0..self.structs.items.len) |index| {
            if (cyclic[index]) continue;
            const info = self.struct_decls.items[index];
            self.diagnostics.scope = self.modules[info.module].file;
            if (self.struct_shapes.items[index].values > helpers.max_struct_values) {
                try self.reportStructTooWide(@intCast(index));
            }
        }
        for (0..self.variants.items.len) |index| {
            if (cyclic[self.structs.items.len + index]) continue;
            const info = self.variant_decls.items[index];
            self.diagnostics.scope = self.modules[info.module].file;
            if (self.variant_shapes.items[index].values > helpers.max_struct_values) {
                try self.fail(
                    "luce.sema.union",
                    info.declaration.span,
                    "union {s} always holds more than {d} values once its largest member is counted; bulk data belongs in a list, map, or array, which is one reference",
                    .{ self.variants.items[index].name, helpers.max_struct_values },
                );
            }
        }
        self.diagnostics.scope = source_mod.root_file;
    }

    // -- pass one: union member fields --------------------------------------

    /// Resolve every union member's payload field types (docs/UNION.md
    /// D1) — after `collectStructs`, because a payload may hold a
    /// struct, and before the shape walk, whose edges these are.
    /// Member field types resolve exactly like struct fields: same
    /// duplicate rule, same function-type deferral, same D4 exposure
    /// check, same trailing-defaults rule (D4).
    fn settleVariantMembers(self: *Analyzer) Error!void {
        for (0..self.variant_decls.items.len) |index| {
            const info = self.variant_decls.items[index];
            self.diagnostics.scope = self.modules[info.module].file;
            const declaration = info.declaration;
            const collected = self.variants.items[index].members;
            const member_defaults = try self.arena.alloc([]context.FieldDefault, collected.len);
            const settled = try self.temporary.alloc(bool, collected.len);
            defer self.temporary.free(settled);
            @memset(settled, false);
            // Declared and collected members differ where one was
            // refused, so they are matched by name — first written
            // occupant wins, exactly as collection kept it; a refused
            // duplicate must not settle the survivor's slot again.
            for (declaration.members) |written| {
                const slot = self.variants.items[index].findMember(written.name) orelse continue;
                if (settled[slot]) continue;
                settled[slot] = true;
                const member = collected[slot];
                const defaults = try self.arena.alloc(context.FieldDefault, written.fields.len);
                member_defaults[slot] = defaults;
                var first_defaulted: ?[]const u8 = null;
                for (written.fields, member.fields, defaults) |field, *resolved_slot, *default_slot| {
                    default_slot.* = .{ .expression = field.default };
                    // The slot stays well-formed whatever the checks
                    // below decide, so a refused field costs one
                    // message and never an undefined read.
                    resolved_slot.* = .{
                        .name = try self.arena.dupe(u8, field.name),
                        .field_type = .long,
                    };
                    if (field.default == null) {
                        if (first_defaulted) |earlier| {
                            try self.fail(
                                "luce.sema.union",
                                field.span,
                                "{s} has a default, so {s} needs one too — the fields with defaults come last",
                                .{ earlier, field.name },
                            );
                            continue;
                        }
                    } else if (first_defaulted == null) {
                        first_defaulted = field.name;
                    }
                    var duplicate = false;
                    for (written.fields) |other| {
                        if (other.name_span.start >= field.name_span.start) break;
                        if (std.mem.eql(u8, other.name, field.name)) duplicate = true;
                    }
                    if (duplicate) {
                        try self.fail(
                            "luce.sema.duplicate",
                            field.name_span,
                            "duplicate field {s} of {s}.{s}",
                            .{ field.name, declaration.name, written.name },
                        );
                        continue;
                    }
                    const field_type = (try self.resolveType(info.module, field.type_name)) orelse continue;
                    if (try self.refuseFunctionPart(field_type, field.type_name.span, "union payload field")) continue;
                    // D4's rule for a member field: a union's members
                    // are always as visible as the union, so a
                    // reachable union may not publish a hidden type
                    // through one (docs/VISIBILITY.md D4).
                    if (declaration.visibility != .private) {
                        if (self.privateMentioned(field_type)) |hidden| {
                            try self.fail(
                                "luce.sema.private",
                                field.type_name.span,
                                "{s} of {s} is public and holds {s}, which is marked private in {s}; mark {s} private or remove the mark on {s}",
                                .{
                                    field.name,
                                    declaration.name,
                                    hidden,
                                    self.markedIn(info.module),
                                    declaration.name,
                                    hidden,
                                },
                            );
                        }
                    }
                    resolved_slot.field_type = field_type;
                }
            }
            self.variant_decls.items[index].member_defaults = member_defaults;
        }
        self.diagnostics.scope = source_mod.root_file;
    }

    /// One step of a containment chain: a combined-graph node, and the
    /// field of it that holds the next node along — for a union, the
    /// member the field belongs to travels beside it.
    const ChainStep = struct { node: u32, member: u32, field: u32 };

    /// The struct is past `max_struct_values`, said in terms of what
    /// the bound actually bounds.
    ///
    /// It bounds what a value of this type *unconditionally* costs to
    /// bring into existence — `zeroOf` emits one instruction per
    /// counted value, and a folded constant is re-emitted at every use
    /// site — which is why `valueCount` flattens a struct field and
    /// stops at an optional one.  That is not a quirk of the counter:
    /// a plain field's payload is part of what the struct *is*, and an
    /// optional field's payload is a separate value that starts absent
    /// and arrives only when a program builds one.  So this check and
    /// the cycle check above are the same rule at two scales — a
    /// struct's unconditional expansion must be finite, and small —
    /// and `?` is what turns "must hold" into "may hold" in both.
    /// The old wording said "expands to N values", which reads as a
    /// claim about the data and left the reader no way to discover
    /// that `?` is an answer here exactly as it is for a cycle.
    ///
    /// The caret goes on the widest struct field, for the same reason
    /// the cycle's goes on the field that opens the loop: that is the
    /// line that gets edited.  A struct that is too wide from its own
    /// scalar fields has no such field to name, and gets the shorter
    /// sentence rather than a misleading one.
    fn reportStructTooWide(self: *Analyzer, index: u32) Error!void {
        const layout = self.structs.items[index];

        // The widest struct field, which is the one worth naming.  A
        // tie goes to the first, so the message is deterministic.
        var widest: ?struct { name: []const u8, of: Type, values: u32 } = null;
        for (layout.fields) |field| {
            if (field.field_type != .strukt) continue;
            const values = self.valueCount(field.field_type);
            if (widest) |found| {
                if (values <= found.values) continue;
            }
            widest = .{ .name = field.name, .of = field.field_type, .values = values };
        }

        const found = widest orelse return self.fail(
            "luce.sema.struct",
            self.struct_decls.items[index].declaration.span,
            "struct {s} always holds more than {d} values; bulk data belongs in a list, map, or array, which is one reference",
            .{ layout.name, helpers.max_struct_values },
        );
        try self.fail(
            "luce.sema.struct",
            self.fieldSpan(index, found.name),
            "struct {s} always holds more than {d} values once its nested structs are counted; {s} is {s}, which is {d} of them on its own; write {s}: {s}? to hold those only when they are there, or move bulk data into a list, map, or array, which is one reference",
            .{
                layout.name,
                helpers.max_struct_values,
                found.name,
                try self.typeName(found.of),
                found.values,
                found.name,
                try self.typeName(found.of),
            },
        );
    }

    /// One diagnostic per cycle, naming the chain that closes it.
    ///
    /// `cyclic` marks every layout *on* a cycle, which for
    /// `struct A: b: B` with `struct B: a: A` is both of them — and a
    /// report per marked layout said "struct A contains itself" and
    /// "struct B contains itself": twice, and false both times.
    /// Neither contains itself.  Together they contain each other,
    /// which is one mistake with one fix, so it gets one message that
    /// walks the loop the reader has to break.
    ///
    /// The chain is the shortest walk from a layout back to itself,
    /// breadth-first over the combined graph's fields — a union's
    /// members' payload fields beside a struct's own — and confined to
    /// nodes that are on a cycle.  The caret goes on the field that
    /// opens it, never the declaration keyword, because the field is
    /// the line that gets edited — and `T?` is the edit, because a
    /// value that may be absent is where the recursion stops
    /// (docs/LANGUAGE.md, docs/UNION.md D12).
    fn reportStructCycles(self: *Analyzer, cyclic: []const bool) Error!void {
        const count = self.structs.items.len + self.variants.items.len;
        const unvisited = std.math.maxInt(u32);

        const reported = try self.temporary.alloc(bool, count);
        defer self.temporary.free(reported);
        @memset(reported, false);
        const came_from = try self.temporary.alloc(u32, count);
        defer self.temporary.free(came_from);
        const came_via = try self.temporary.alloc(u32, count);
        defer self.temporary.free(came_via);
        const came_member = try self.temporary.alloc(u32, count);
        defer self.temporary.free(came_member);

        var queue: std.ArrayList(u32) = .empty;
        defer queue.deinit(self.temporary);
        var chain: std.ArrayList(ChainStep) = .empty;
        defer chain.deinit(self.temporary);
        var written: std.ArrayList(u8) = .empty;
        defer written.deinit(self.temporary);

        for (0..count) |start_index| {
            const start: u32 = @intCast(start_index);
            if (!cyclic[start] or reported[start]) continue;

            // Breadth-first from `start`, stopping at the first edge
            // that points back at it: the first such edge found closes
            // the shortest cycle through `start`.
            @memset(came_from, unvisited);
            came_from[start] = start; // visited; never re-entered
            queue.clearRetainingCapacity();
            try queue.append(self.temporary, start);
            var closing: ?ChainStep = null;
            var head: usize = 0;
            search: while (head < queue.items.len) : (head += 1) {
                const node = queue.items[head];
                var cursor: GraphStep = .{ .node = node };
                while (self.containedNodeAt(&cursor)) |held| {
                    // The cursor has already moved past the field it
                    // just answered from, so the edge is one back.
                    const edge: ChainStep = .{
                        .node = node,
                        .member = cursor.member,
                        .field = cursor.field - 1,
                    };
                    if (held == start) {
                        closing = edge;
                        break :search;
                    }
                    if (!cyclic[held] or came_from[held] != unvisited) continue;
                    came_from[held] = node;
                    came_member[held] = edge.member;
                    came_via[held] = edge.field;
                    try queue.append(self.temporary, held);
                }
            }
            // `start` is marked cyclic, so an edge back to it exists.
            const closed = closing orelse continue;

            // Walk the parent links back to `start`, then turn the
            // chain around so it reads the way the source does.
            chain.clearRetainingCapacity();
            try chain.append(self.temporary, closed);
            var cursor = closed.node;
            while (cursor != start) {
                const parent = came_from[cursor];
                try chain.append(self.temporary, .{
                    .node = parent,
                    .member = came_member[cursor],
                    .field = came_via[cursor],
                });
                cursor = parent;
            }
            std.mem.reverse(ChainStep, chain.items);
            for (chain.items) |step| reported[step.node] = true;

            written.clearRetainingCapacity();
            for (chain.items, 0..) |step, position| {
                if (position != 0) {
                    try written.appendSlice(self.temporary, ", ");
                    if (position + 1 == chain.items.len) try written.appendSlice(self.temporary, "and ");
                }
                const field = self.chainField(step);
                try written.print(self.temporary, "{s} is {s}", .{
                    try self.chainPlace(step),
                    try self.typeName(field.field_type),
                });
            }

            const opening = chain.items[0];
            const opening_field = self.chainField(opening);
            self.diagnostics.scope = self.modules[self.nodeModule(opening.node)].file;
            try self.fail(
                if (start < self.structs.items.len) "luce.sema.struct" else "luce.sema.union",
                self.chainSpan(opening),
                "{s} {s} contains itself: {s}; a {s} is a value, so write {s}: {s}? to let the chain end at absence",
                .{
                    self.nodeKind(start),
                    self.nodeName(start),
                    written.items,
                    self.nodeKind(start),
                    opening_field.name,
                    try self.typeName(opening_field.field_type),
                },
            );
        }
    }

    /// The declaring module of one combined-graph node.
    fn nodeModule(self: *const Analyzer, node: u32) usize {
        if (node < self.structs.items.len) return self.struct_decls.items[node].module;
        return self.variant_decls.items[node - self.structs.items.len].module;
    }

    /// The declaration keyword of one combined-graph node, for a
    /// sentence: `struct` or `union`, as the reader wrote it.
    fn nodeKind(self: *const Analyzer, node: u32) []const u8 {
        return if (node < self.structs.items.len) "struct" else "union";
    }

    fn nodeName(self: *const Analyzer, node: u32) []const u8 {
        if (node < self.structs.items.len) return self.structs.items[node].name;
        return self.variants.items[node - self.structs.items.len].name;
    }

    /// The field one chain step names — a struct's own, or a union
    /// member's payload field.
    fn chainField(self: *const Analyzer, step: ChainStep) types.StructField {
        if (step.node < self.structs.items.len) {
            return self.structs.items[step.node].fields[step.field];
        }
        const declared = self.variants.items[step.node - self.structs.items.len];
        return declared.members[step.member].fields[step.field];
    }

    /// One chain step as a reader would spell it: `Node.next` for a
    /// struct field, `Json.array.items` for a union member's.
    fn chainPlace(self: *Analyzer, step: ChainStep) Error![]const u8 {
        if (step.node < self.structs.items.len) {
            const layout = self.structs.items[step.node];
            return std.fmt.allocPrint(self.arena, "{s}.{s}", .{
                layout.name,
                layout.fields[step.field].name,
            });
        }
        const declared = self.variants.items[step.node - self.structs.items.len];
        const member = declared.members[step.member];
        return std.fmt.allocPrint(self.arena, "{s}.{s}.{s}", .{
            declared.name,
            member.name,
            member.fields[step.field].name,
        });
    }

    /// Where a chain step's field is written in its own source.
    fn chainSpan(self: *const Analyzer, step: ChainStep) Span {
        const field = self.chainField(step);
        if (step.node < self.structs.items.len) {
            return self.fieldSpan(step.node, field.name);
        }
        const info = self.variant_decls.items[step.node - self.structs.items.len];
        const member = self.variants.items[step.node - self.structs.items.len].members[step.member];
        for (info.declaration.members) |written| {
            if (!std.mem.eql(u8, written.name, member.name)) continue;
            for (written.fields) |declared| {
                if (std.mem.eql(u8, declared.name, field.name)) return declared.span;
            }
            return written.span;
        }
        return info.declaration.span;
    }

    /// Where a layout's field is written in its own source.  Layout
    /// fields are a subset of declared ones — a duplicate or an
    /// unresolvable type is reported and dropped — so the match is by
    /// name, and the declaration stands in if it somehow fails.
    fn fieldSpan(self: *const Analyzer, layout: u32, name: []const u8) Span {
        const declaration = self.struct_decls.items[layout].declaration;
        for (declaration.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.span;
        }
        return declaration.span;
    }

    /// One pass over the containment graph — structs and unions in one
    /// node space, structs first — marking every layout on a cycle and
    /// filling in the shape of every one that is not (docs/UNION.md
    /// D12: only one member is ever live, but every member is an edge,
    /// so a member that contains the union makes it infinite whichever
    /// member it is).
    ///
    /// This is Tarjan's strongly connected components, written with an
    /// explicit stack.  Both jobs were recursive one-question-at-a-time
    /// walks before, and both were exponential: asking "does this
    /// struct contain an object" or "does it contain itself" re-walked
    /// every *path* through the graph, so a struct with two struct
    /// fields doubled the work per level — twenty levels of that is a
    /// million walks, from forty lines of source, per question.  A
    /// component with more than one member (or a layout naming itself)
    /// is a cycle; everything else closes after the layouts it
    /// contains, which is exactly when its shape can be summed.
    fn settleStructGraph(self: *Analyzer, cyclic: []bool) Error!void {
        const struct_count = self.structs.items.len;
        const count = struct_count + self.variants.items.len;
        try self.struct_shapes.appendNTimes(self.temporary, .{ .values = 1 }, struct_count);
        try self.variant_shapes.appendNTimes(self.temporary, .{ .values = 1 }, self.variants.items.len);
        if (count == 0) return;

        const unvisited = std.math.maxInt(u32);
        const order = try self.temporary.alloc(u32, count);
        defer self.temporary.free(order);
        const lowest = try self.temporary.alloc(u32, count);
        defer self.temporary.free(lowest);
        const open = try self.temporary.alloc(bool, count);
        defer self.temporary.free(open);
        @memset(order, unvisited);
        @memset(open, false);

        // Tarjan's component stack, and the explicit depth-first one.
        var pending: std.ArrayList(u32) = .empty;
        defer pending.deinit(self.temporary);
        var path: std.ArrayList(GraphStep) = .empty;
        defer path.deinit(self.temporary);

        var next_order: u32 = 0;
        for (0..count) |root| {
            if (order[root] != unvisited) continue;
            order[root] = next_order;
            lowest[root] = next_order;
            next_order += 1;
            open[root] = true;
            try pending.append(self.temporary, @intCast(root));
            try path.append(self.temporary, .{ .node = @intCast(root) });

            while (path.items.len != 0) {
                // `step` points into `path`, which the descent below
                // may grow: everything read through it is read before
                // that append, and nothing is read after.
                const step = &path.items[path.items.len - 1];
                const node = step.node;
                if (self.containedNodeAt(step)) |held| {
                    if (held == node) cyclic[node] = true;
                    if (order[held] == unvisited) {
                        order[held] = next_order;
                        lowest[held] = next_order;
                        next_order += 1;
                        open[held] = true;
                        try pending.append(self.temporary, held);
                        try path.append(self.temporary, .{ .node = held });
                    } else if (open[held]) {
                        lowest[node] = @min(lowest[node], order[held]);
                    }
                    continue;
                }

                // Every field visited: this node closes.  The layouts
                // it holds are either closed (their shapes are final)
                // or still open, which means a cycle the component
                // check below is about to catch.
                if (node < struct_count) {
                    self.struct_shapes.items[node] = self.sumShape(node);
                } else {
                    self.variant_shapes.items[node - struct_count] =
                        self.sumVariantShape(@intCast(node - struct_count));
                }
                _ = path.pop();
                if (path.items.len != 0) {
                    const parent = path.items[path.items.len - 1].node;
                    lowest[parent] = @min(lowest[parent], lowest[node]);
                }
                if (lowest[node] != order[node]) continue;

                // The root of a component: everything pushed at or
                // after it is a member.  More than one member means
                // they hold each other, so none has a finite value.
                var first = pending.items.len;
                while (pending.items[first - 1] != node) first -= 1;
                first -= 1;
                const members = pending.items[first..];
                for (members) |member| open[member] = false;
                if (members.len > 1) {
                    for (members) |member| cyclic[member] = true;
                }
                pending.shrinkRetainingCapacity(first);
            }
        }
        for (cyclic, 0..) |on_cycle, index| {
            if (!on_cycle) continue;
            if (index < struct_count) {
                self.struct_shapes.items[index] = .{ .values = 1 };
            } else {
                self.variant_shapes.items[index - struct_count] = .{ .values = 1 };
            }
        }
    }

    /// One node of the combined containment graph with the cursor of
    /// the depth-first walk over its fields: structs advance `field`
    /// alone, unions advance `member` and `field` together, so a
    /// resumed scan never re-reads a field it already passed.
    const GraphStep = struct { node: u32, member: u32 = 0, field: u32 = 0 };

    /// The next combined-graph node one of the step's fields names,
    /// advancing the cursor past it, or null once the fields run out.
    fn containedNodeAt(self: *const Analyzer, step: *GraphStep) ?u32 {
        if (step.node < self.structs.items.len) {
            const fields = self.structs.items[step.node].fields;
            while (step.field < fields.len) {
                const held = fields[step.field].field_type;
                step.field += 1;
                if (self.graphNode(held)) |node| return node;
            }
            return null;
        }
        const members = self.variants.items[step.node - self.structs.items.len].members;
        while (step.member < members.len) {
            const fields = members[step.member].fields;
            while (step.field < fields.len) {
                const held = fields[step.field].field_type;
                step.field += 1;
                if (self.graphNode(held)) |node| return node;
            }
            step.member += 1;
            step.field = 0;
        }
        return null;
    }

    /// The combined-graph node a field type expands into, or null for
    /// a type that stops the walk — a container is a handle, an
    /// optional stops at absence, and both are the prescribed fixes.
    fn graphNode(self: *const Analyzer, of: Type) ?u32 {
        return switch (of) {
            .strukt => |index| index,
            .variant => |index| @intCast(self.structs.items.len + index),
            else => null,
        };
    }

    /// Sum one layout's shape from its fields' — valid only once every
    /// struct field's own shape is final, which is what the closing
    /// order above guarantees.
    fn sumShape(self: *const Analyzer, layout: u32) StructShape {
        var shape: StructShape = .{};
        for (self.structs.items[layout].fields) |field| {
            if (self.carriesObjects(field.field_type)) shape.carries = true;
            shape.values +|= self.valueCount(field.field_type);
        }
        shape.values = @min(shape.values, helpers.max_struct_values + 1);
        return shape;
    }

    /// Sum one union's shape from its members' (docs/UNION.md D9,
    /// D12): `carries` is the OR over every member's fields — the
    /// predicate is type-level, and the compiler does not know which
    /// member a value holds — and the expansion is 1 for the tag plus
    /// the *largest* member's, because only one member is ever live.
    fn sumVariantShape(self: *const Analyzer, index: u32) StructShape {
        var shape: StructShape = .{ .values = 0 };
        var widest: u32 = 0;
        for (self.variants.items[index].members) |member| {
            var member_values: u32 = 0;
            for (member.fields) |field| {
                if (self.carriesObjects(field.field_type)) shape.carries = true;
                member_values +|= self.valueCount(field.field_type);
            }
            widest = @max(widest, member_values);
        }
        shape.values = @min(1 +| widest, helpers.max_struct_values + 1);
        return shape;
    }

    // -- pass one: file-scope constants -----------------------------------
    //
    // Only the registration is here; folding one is `constants.zig`'s,
    // and `run` calls it right after this so an error in a constant
    // nothing reads still reports.

    /// Register every module's top-level `const` declarations under their
    /// qualified names, refusing a reserved or duplicate one.  Nothing
    /// is evaluated yet: an enum member's value may name a constant and
    /// a constant may name an enum member, so every name has to exist
    /// before either fold runs (docs/ENUMS.md D8).
    fn registerConstants(self: *Analyzer) Error!void {
        for (self.modules, 0..) |module, module_index| {
            self.diagnostics.scope = module.file;
            for (module.tree.constants) |*declaration| {
                if (isReserved(declaration.name)) {
                    try self.fail("luce.sema.reserved", declaration.name_span, "{s} is a reserved name", .{declaration.name});
                    continue;
                }
                const qualified = try self.qualify(module.prefix, declaration.name);
                if (try self.firstDeclarationOf(qualified)) |where| {
                    try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                        declaration.name,
                        where,
                    });
                    continue;
                }
                const index: u32 = @intCast(self.constant_infos.items.len);
                try self.constant_names.put(self.temporary, qualified, index);
                try self.constant_infos.append(self.temporary, .{
                    .declaration = declaration,
                    .module = module_index,
                });
            }
        }
        self.diagnostics.scope = source_mod.root_file;
    }

    // -- pass one: function signatures, and the entry ---------------------

    fn collectFunctions(self: *Analyzer) Error!void {
        for (self.modules, 0..) |module, module_index| {
            self.diagnostics.scope = module.file;
            for (module.tree.functions) |*declaration| {
                const qualified = try self.qualify(module.prefix, declaration.name);
                try self.collectFunction(declaration, qualified, module_index, true, null);
            }
            for (module.tree.structs) |*declaration| {
                const owner = self.struct_names.get(
                    try self.qualify(module.prefix, declaration.name),
                );
                for (declaration.functions) |*function| {
                    const member = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{
                        declaration.name,
                        function.name,
                    });
                    const qualified = try self.qualify(module.prefix, member);
                    try self.collectFunction(
                        function,
                        qualified,
                        module_index,
                        false,
                        if (owner) |index| .{ .strukt = index } else null,
                    );
                }
            }
            // An enum's functions are collected exactly as a struct's
            // are, and named the same way: `Method.name` is one lookup
            // whichever keyword declared `Method` (docs/ENUMS.md D7).
            for (module.tree.enums) |*declaration| {
                const owner = self.enum_names.get(
                    try self.qualify(module.prefix, declaration.name),
                );
                for (declaration.functions) |*function| {
                    const member = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{
                        declaration.name,
                        function.name,
                    });
                    const qualified = try self.qualify(module.prefix, member);
                    try self.collectFunction(
                        function,
                        qualified,
                        module_index,
                        false,
                        if (owner) |index| .{ .enumeration = self.enumType(index).enumeration } else null,
                    );
                }
            }
            // And a union's, under the same rules (docs/UNION.md D17
            // and its SELF amendment): plain member functions are
            // methods with implied self, `static func` declares a
            // namespace function, and receiver writing is inferred.
            for (module.tree.unions) |*declaration| {
                const owner = self.variant_names.get(
                    try self.qualify(module.prefix, declaration.name),
                );
                for (declaration.functions) |*function| {
                    const member = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{
                        declaration.name,
                        function.name,
                    });
                    const qualified = try self.qualify(module.prefix, member);
                    try self.collectFunction(
                        function,
                        qualified,
                        module_index,
                        false,
                        if (owner) |index| .{ .variant = index } else null,
                    );
                }
            }
        }
        self.diagnostics.scope = source_mod.root_file;
        try self.checkEntry();
    }

    /// Infer the one receiver fact source no longer spells: whether a
    /// method writes its implicit `self` (docs/SELF.md D3).
    ///
    /// The walk is a fixed point because a read-looking wrapper may
    /// call a writer declared later, and recursion must not make the
    /// answer depend on declaration order.  Only `self.m()` propagates
    /// a value-receiver write.  `self.items.append()` mutates the
    /// borrowed object's contents and deliberately does not: the
    /// value/object line is unchanged (D6).
    fn inferReceiverWrites(self: *Analyzer) Error!void {
        var changed = true;
        while (changed) {
            changed = false;
            for (self.functions.items) |*info| {
                if (info.receiver != .reads) continue;
                if (!self.blockWritesReceiver(info, info.declaration.body)) continue;
                info.receiver = .writes;
                changed = true;
            }
        }
    }

    fn blockWritesReceiver(
        self: *const Analyzer,
        info: *const FunctionDeclInfo,
        block: ast.Block,
    ) bool {
        for (block.statements) |statement| {
            if (self.statementWritesReceiver(info, statement)) return true;
        }
        return false;
    }

    fn statementWritesReceiver(
        self: *const Analyzer,
        info: *const FunctionDeclInfo,
        statement: ast.Statement,
    ) bool {
        return switch (statement) {
            .assign => |assign| selfTarget(assign.target) or
                self.targetEvaluationWritesReceiver(info, assign.target) or
                self.expressionWritesReceiver(info, assign.value),
            .assign_many => |assign| blk: {
                for (assign.names) |name| {
                    if (std.mem.eql(u8, name.text, "self")) break :blk true;
                }
                break :blk self.expressionWritesReceiver(info, assign.value);
            },
            .let => |binding| self.expressionWritesReceiver(info, binding.value),
            .variable => |binding| binding.value != null and
                self.expressionWritesReceiver(info, binding.value.?),
            .destructure => |binding| self.expressionWritesReceiver(info, binding.value),
            .expression => |written| self.expressionWritesReceiver(info, written.value),
            .return_statement => |returned| blk: {
                for (returned.values) |value| {
                    if (self.expressionWritesReceiver(info, value)) break :blk true;
                }
                break :blk false;
            },
            .conditional => |conditional| self.expressionWritesReceiver(info, conditional.condition) or
                self.blockWritesReceiver(info, conditional.then_block) or
                (conditional.else_block != null and
                    self.blockWritesReceiver(info, conditional.else_block.?)),
            .while_loop => |loop| self.expressionWritesReceiver(info, loop.condition) or
                self.blockWritesReceiver(info, loop.body),
            .for_range => |loop| self.expressionWritesReceiver(info, loop.start) or
                self.expressionWritesReceiver(info, loop.end) or
                self.blockWritesReceiver(info, loop.body),
            .for_each => |loop| self.expressionWritesReceiver(info, loop.iterable) or
                self.blockWritesReceiver(info, loop.body),
            .guarded => |guarded| self.statementWritesReceiver(info, guarded.attempt.*) or
                self.blockWritesReceiver(info, guarded.handler),
            .match => |matched| blk: {
                if (self.expressionWritesReceiver(info, matched.scrutinee)) break :blk true;
                for (matched.arms) |arm| {
                    if (self.blockWritesReceiver(info, arm.body)) break :blk true;
                }
                break :blk matched.else_block != null and
                    self.blockWritesReceiver(info, matched.else_block.?);
            },
            .break_statement, .continue_statement => false,
        };
    }

    fn expressionWritesReceiver(
        self: *const Analyzer,
        info: *const FunctionDeclInfo,
        expression: *const ast.Expression,
    ) bool {
        return switch (expression.*) {
            .method => |method| blk: {
                if (method.target.* == .name and
                    std.mem.eql(u8, method.target.name.text, "self") and
                    self.memberWritesReceiver(info, method.name))
                {
                    break :blk true;
                }
                if (self.expressionWritesReceiver(info, method.target)) break :blk true;
                for (method.arguments) |argument| {
                    if (self.expressionWritesReceiver(info, argument.value)) break :blk true;
                }
                break :blk false;
            },
            .call => |call| blk: {
                if (std.mem.eql(u8, call.callee, "free") and
                    call.arguments.len == 1 and
                    expressionIsSelf(call.arguments[0].value))
                {
                    break :blk true;
                }
                for (call.arguments) |argument| {
                    if (self.expressionWritesReceiver(info, argument.value)) break :blk true;
                }
                break :blk false;
            },
            .binary => |binary| self.expressionWritesReceiver(info, binary.left) or
                self.expressionWritesReceiver(info, binary.right),
            .unary => |unary| self.expressionWritesReceiver(info, unary.operand),
            .field => |field| self.expressionWritesReceiver(info, field.target),
            .index => |index| blk: {
                if (self.expressionWritesReceiver(info, index.target)) break :blk true;
                for (index.indices) |subscript| {
                    if (self.expressionWritesReceiver(info, subscript)) break :blk true;
                }
                break :blk false;
            },
            .slice_range => |slice| self.expressionWritesReceiver(info, slice.target) or
                (slice.start != null and self.expressionWritesReceiver(info, slice.start.?)) or
                (slice.end != null and self.expressionWritesReceiver(info, slice.end.?)),
            .list_literal => |literal| blk: {
                for (literal.elements) |element| {
                    if (self.expressionWritesReceiver(info, element)) break :blk true;
                }
                break :blk false;
            },
            .map_literal => |literal| blk: {
                for (literal.entries) |entry| {
                    if (self.expressionWritesReceiver(info, entry.key) or
                        self.expressionWritesReceiver(info, entry.value)) break :blk true;
                }
                break :blk false;
            },
            .new_object => |new| blk: {
                for (new.dims) |dimension| {
                    if (self.expressionWritesReceiver(info, dimension)) break :blk true;
                }
                break :blk false;
            },
            .give => |give| expressionIsSelf(give.operand) or
                self.expressionWritesReceiver(info, give.operand),
            .copy => |copy| self.expressionWritesReceiver(info, copy.operand),
            .try_call => |attempt| self.expressionWritesReceiver(info, attempt.operand),
            .spawn => |spawn| self.expressionWritesReceiver(info, spawn.call),
            // A lambda cannot carry self.  Its body is checked in its
            // synthesized function and must not change the enclosing
            // method's receiver classification.
            .lambda => false,
            .name,
            .int_literal,
            .float_literal,
            .string_literal,
            .bool_literal,
            .none_literal,
            => false,
        };
    }

    fn memberWritesReceiver(
        self: *const Analyzer,
        caller: *const FunctionDeclInfo,
        name: []const u8,
    ) bool {
        const owner = caller.enclosing orelse return false;
        for (self.functions.items) |candidate| {
            if (candidate.receiver != .writes) continue;
            const candidate_owner = candidate.enclosing orelse continue;
            if (!candidate_owner.asType().eql(owner.asType())) continue;
            if (candidate.module != caller.module) continue;
            if (std.mem.eql(u8, candidate.declaration.name, name)) return true;
        }
        return false;
    }

    fn selfTarget(target: ast.Target) bool {
        return switch (target) {
            .name => |name| std.mem.eql(u8, name.text, "self"),
            .field => |field| std.mem.eql(u8, field.base, "self"),
            .chain => |chain| expressionRootIsSelf(chain.place),
            // Index assignment mutates an object's contents, not the
            // value holding that reference (SELF D6).
            .index => false,
        };
    }

    /// A store's place is evaluated before it is written.  That
    /// evaluation can itself call a writing method —
    /// `items[self.bump()] = value` — even when the eventual store is
    /// into an object's contents and is therefore not a self-value
    /// write.  Keep that question separate from `selfTarget` so D6's
    /// value/object line stays visible.
    fn targetEvaluationWritesReceiver(
        self: *const Analyzer,
        info: *const FunctionDeclInfo,
        target: ast.Target,
    ) bool {
        return switch (target) {
            .name, .field => false,
            .index => |index| blk: {
                if (self.expressionWritesReceiver(info, index.base)) break :blk true;
                for (index.indices) |subscript| {
                    if (self.expressionWritesReceiver(info, subscript)) break :blk true;
                }
                break :blk false;
            },
            .chain => |chain| self.expressionWritesReceiver(info, chain.place),
        };
    }

    fn expressionRootIsSelf(expression: *const ast.Expression) bool {
        return switch (expression.*) {
            .name => |name| std.mem.eql(u8, name.text, "self"),
            .field => |field| expressionRootIsSelf(field.target),
            else => false,
        };
    }

    fn expressionIsSelf(expression: *const ast.Expression) bool {
        return expression.* == .name and std.mem.eql(u8, expression.name.text, "self");
    }

    fn collectFunction(
        self: *Analyzer,
        declaration: *const ast.FuncDecl,
        name: []const u8,
        module: usize,
        top_level: bool,
        /// The declaration this one sits inside, or null at file scope.
        /// It is what gives `self` its type, and what makes `self` at
        /// file scope a diagnostic rather than a crash.
        enclosing: ?context.Enclosing,
    ) Error!void {
        const in_root = self.modules[module].prefix.len == 0;
        if (isReserved(declaration.name)) {
            try self.fail("luce.sema.reserved", declaration.name_span, "{s} is a reserved name", .{declaration.name});
            return;
        }
        if (self.function_names.contains(name) or
            self.constant_names.contains(name) or
            (top_level and (self.struct_names.contains(name) or self.enum_names.contains(name))))
        {
            try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                declaration.name,
                (try self.firstDeclarationOf(name)) orelse "",
            });
            return;
        }

        const is_entry = top_level and in_root and std.mem.eql(u8, declaration.name, "main");
        // The entry is selected by name and called by the runtime
        // through the ABI — there is no import edge for a marker to
        // gate, so `private` on it could only assert something false
        // (VISIBILITY.md D7).  `public` is inert-legal like any other
        // restated default.
        if (is_entry and declaration.visibility == .private) {
            try self.fail(
                "luce.sema.private",
                declaration.name_span,
                "main is the entry and cannot be private: the runtime starts it",
                .{},
            );
        }
        // Whether this declaration is part of the module's reachable
        // surface, for D4 below: a private function, or any member of
        // a private struct, publishes nothing.
        const surface = declaration.visibility != .private and
            (enclosing == null or switch (enclosing.?) {
                .strukt => |index| self.struct_decls.items[index].declaration.visibility != .private,
                .enumeration => |reference| self.enum_decls.items[reference.index].declaration.visibility != .private,
                .variant => |index| self.variant_decls.items[index].declaration.visibility != .private,
            });
        var parameter_types: std.ArrayList(Type) = .empty;
        defer parameter_types.deinit(self.arena);
        var parameter_modes: std.ArrayList(ast.ParameterMode) = .empty;
        defer parameter_modes.deinit(self.arena);
        var parameter_defaults: std.ArrayList(?TypedConstant) = .empty;
        defer parameter_defaults.deinit(self.arena);
        // The first parameter that declared a default, for D3's
        // sentence when a required one follows it.
        var first_defaulted: ?[]const u8 = null;
        // A plain function inside a struct or enum has one implicit
        // leading receiver.  `static` is the explicit exception.  The
        // source parameter list contains only what the caller writes;
        // MIR still keeps self as logical parameter zero so every
        // existing method lookup keeps one shape (docs/SELF.md D1-D2).
        var receiver: context.Receiver = .not;
        if (enclosing != null and !declaration.is_static) {
            receiver = .reads;
            try parameter_types.append(self.arena, enclosing.?.asType());
            try parameter_modes.append(self.arena, .borrow);
            try parameter_defaults.append(self.arena, null);
        }
        // The entry's written parameter is collected like every other
        // one: it is the command line, it has a type, and `checkEntry`
        // below is what says which type it has to be (S44).
        for (declaration.parameters) |parameter| {
            const resolved = (try self.resolveType(module, parameter.type_name)) orelse continue;
            // D4: a public surface names public types.  Only the
            // author of the marks can trip this, and the refusal names
            // both edits that would restore honesty (VISIBILITY.md §2).
            if (surface) {
                if (self.privateMentioned(resolved)) |hidden| {
                    try self.fail(
                        "luce.sema.private",
                        parameter.type_name.span,
                        "{s} is public and takes {s}, which is marked private in {s}; mark {s} private or remove the mark on {s}",
                        .{ declaration.name, hidden, self.markedIn(module), declaration.name, hidden },
                    );
                    continue;
                }
            }
            if (parameter.mode == .give and !self.carriesObjects(resolved)) {
                try self.fail(
                    "luce.sema.own",
                    parameter.span,
                    "give applies to containers and resources (list, map, array, builder, file, task) and structs that carry them, not values [OWNERSHIP.md S32]",
                    .{},
                );
                continue;
            }
            // Defaults are trailing (docs/ARGS.md D3): a parameter
            // with one may be followed only by parameters with one.
            // It is what keeps a defaulted signature one signature
            // with a shorter legal spelling rather than an overload
            // set, and what stops a must-be-named parameter arriving
            // through a hole in the ordering rule.
            if (parameter.default == null) {
                if (first_defaulted) |earlier| {
                    try self.fail(
                        "luce.sema.call",
                        parameter.span,
                        "{s} has a default, so {s} needs one too — the parameters with defaults come last",
                        .{ earlier, parameter.name },
                    );
                    continue;
                }
            } else if (first_defaulted == null) {
                first_defaulted = parameter.name;
            }
            var folded: ?TypedConstant = null;
            if (parameter.default) |written| {
                folded = (try self.foldDefault(module, declaration, parameter, resolved, written)) orelse continue;
            }
            try parameter_types.append(self.arena, resolved);
            try parameter_modes.append(self.arena, parameter.mode);
            try parameter_defaults.append(self.arena, folded);
        }
        var results: std.ArrayList(Type) = .empty;
        defer results.deinit(self.arena);
        for (declaration.returns) |written| {
            const resolved = (try self.resolveType(module, written)) orelse continue;
            if (surface) {
                if (self.privateMentioned(resolved)) |hidden| {
                    try self.fail(
                        "luce.sema.private",
                        written.span,
                        "{s} is public and answers {s}, which is marked private in {s}; mark {s} private or remove the mark on {s}",
                        .{ declaration.name, hidden, self.markedIn(module), declaration.name, hidden },
                    );
                    continue;
                }
            }
            try results.append(self.arena, resolved);
        }
        // SELF retired the old receiver-at-result-zero channel.  A
        // writing receiver now travels through MIR's inout call edge;
        // the ordinary answer is exactly what the declaration says.
        var channel: std.ArrayList(Type) = .empty;
        defer channel.deinit(self.arena);
        try channel.appendSlice(self.arena, results.items);
        // The synthesized layout a return shape rides in is settled
        // after every signature is collected — `synthesizeShapes`
        // below — because the layout table must not grow while a body
        // is being lowered against a snapshot of it.
        const return_type: Type = if (channel.items.len == 1) channel.items[0] else .none;

        const index: u32 = @intCast(self.functions.items.len);
        try self.function_names.put(self.temporary, name, index);
        try self.functions.append(self.arena, .{
            .declaration = declaration,
            .name = try self.arena.dupe(u8, name),
            .module = module,
            .parameter_types = try parameter_types.toOwnedSlice(self.arena),
            .parameter_modes = try parameter_modes.toOwnedSlice(self.arena),
            .parameter_defaults = try parameter_defaults.toOwnedSlice(self.arena),
            .receiver = receiver,
            .enclosing = enclosing,
            .results = try results.toOwnedSlice(self.arena),
            .channel = try channel.toOwnedSlice(self.arena),
            .return_type = return_type,
            .fallible = declaration.fallible,
            .is_entry = is_entry,
        });
    }

    /// Register the top-level function a lambda becomes
    /// (docs/FUNCTIONS.md D2), and answer its index.
    ///
    /// Not `collectFunction`: there is no written signature to resolve
    /// — the landing site's is the signature — no name to check for
    /// collisions, because the name is unforgeable, and no visibility to
    /// read, because nothing can name this function but the value that
    /// was just made of it.  What it shares with a declared function is
    /// everything after that: it is lowered by the same loop, checked by
    /// the same walk, and called through the same instruction.
    pub fn registerLambda(
        self: *Analyzer,
        declaration: *const ast.FuncDecl,
        module: usize,
        signature: types.Signature,
        /// Every local in scope where the lambda was written.  Its name
        /// drives capture diagnostics and its span preserves the normal
        /// no-shadowing diagnostic after the body is lifted.
        enclosing_locals: []const context.EnclosingLocal,
    ) Error!u32 {
        const parameter_types = try self.arena.alloc(Type, signature.parameters.len);
        const parameter_modes = try self.arena.alloc(ast.ParameterMode, signature.parameters.len);
        const parameter_defaults = try self.arena.alloc(?TypedConstant, signature.parameters.len);
        for (signature.parameters, parameter_types, parameter_modes, parameter_defaults) |parameter, *held, *mode, *default| {
            held.* = parameter.value_type;
            mode.* = if (parameter.gives) .give else .borrow;
            default.* = null;
        }
        const results = try self.arena.alloc(Type, if (signature.result == .none) 0 else 1);
        if (results.len == 1) results[0] = signature.result;
        const index: u32 = @intCast(self.functions.items.len);
        try self.functions.append(self.arena, .{
            .declaration = declaration,
            .name = declaration.name,
            .module = module,
            .parameter_types = parameter_types,
            .parameter_modes = parameter_modes,
            .parameter_defaults = parameter_defaults,
            .results = results,
            .channel = results,
            .return_type = signature.result,
            .fallible = false,
            .is_entry = false,
            .enclosing_locals = enclosing_locals,
        });
        return index;
    }

    /// Instantiate one closed, compiler-owned standard-library
    /// template at concrete monomorphic parameter types.
    ///
    /// Luce exposes no user generics.  `std.lists.sort_by` nevertheless
    /// has to serve `list(T)` for the receiver's actual T, so its routed
    /// method takes the same narrow route lambdas take: the ordinary
    /// Luce body is collected once, this method gives a clone concrete
    /// parameter types, and the normal lowering loop checks and lowers
    /// it like every other function.  No MIR instruction or runtime
    /// callback is added (FUNCTIONS.md D2, D6).
    pub fn registerStandardSpecialization(
        self: *Analyzer,
        template_name: []const u8,
        specialized_name: []const u8,
        parameter_types: []const Type,
    ) Error!?u32 {
        const template_index = self.function_names.get(template_name) orelse return null;
        const template = self.functions.items[template_index];
        const source = self.diagnostics.sources.at(self.modules[template.module].file) orelse return null;
        if (source.kind != .standard or
            template.declaration.visibility != .private or
            template.parameter_types.len != parameter_types.len or
            template.return_type != .none or
            template.fallible or
            template.is_entry or
            template.receiver != .not or
            template.enclosing != null)
        {
            return null;
        }
        for (template.parameter_modes) |mode| {
            if (mode != .borrow) return null;
        }
        for (template.parameter_defaults) |default| {
            if (default != null) return null;
        }

        // Cache on types, not their rendered names.  Names are for
        // traces; `Type.eql` is the language's identity relation.
        for (self.standard_specializations.items) |existing| {
            if (existing.template != template_index or existing.parameters.len != parameter_types.len) continue;
            var same = true;
            for (existing.parameters, parameter_types) |held, wanted| {
                if (!held.eql(wanted)) {
                    same = false;
                    break;
                }
            }
            if (same) return existing.function;
        }

        const declaration = try self.arena.create(ast.FuncDecl);
        declaration.* = template.declaration.*;
        declaration.name = try self.arena.dupe(u8, specialized_name);
        // The import and routing gate visibility at the call site.  The
        // clone itself must be callable from that site even when its
        // checked source template is private (the object-owning arm).
        declaration.visibility = .public;

        const index: u32 = @intCast(self.functions.items.len);
        try self.functions.append(self.arena, .{
            .declaration = declaration,
            .name = declaration.name,
            .module = template.module,
            .parameter_types = try self.arena.dupe(Type, parameter_types),
            .parameter_modes = template.parameter_modes,
            .parameter_defaults = template.parameter_defaults,
            .receiver = template.receiver,
            .enclosing = template.enclosing,
            .results = template.results,
            .channel = template.channel,
            .return_type = template.return_type,
            .fallible = template.fallible,
            .is_entry = false,
        });
        try self.standard_specializations.append(self.arena, .{
            .template = template_index,
            .parameters = self.functions.items[index].parameter_types,
            .function = index,
        });
        return index;
    }

    /// Fold one parameter default at the parameter's own type
    /// (docs/ARGS.md D2), using the same folder as file-scope `const`.
    /// A value default is materialized at each call as the register its
    /// written expression would have produced; a container default
    /// names one program-root row shared by every omitted call.  Null
    /// after reporting.
    fn foldDefault(
        self: *Analyzer,
        module: usize,
        declaration: *const ast.FuncDecl,
        parameter: ast.Parameter,
        resolved: Type,
        written: *const ast.Expression,
    ) Error!?TypedConstant {
        // A give parameter takes ownership, while a program-root
        // container has no ownership to transfer.  Borrowed defaults
        // may be container constants: every omitted call then borrows
        // the same per-runtime root (docs/CONSTANTS.md, Surface
        // interactions).
        if (parameter.mode == .give) {
            try self.fail(
                "luce.sema.own",
                parameter.span,
                "a give parameter takes ownership, so its default cannot be a shared constant container [OWNERSHIP.md S13, S32, S46]",
                .{},
            );
            return null;
        }
        if (helpers.deeperThan(written, helpers.max_expression_depth)) {
            try self.fail(
                "luce.sema.nesting",
                parameter.span,
                "expression nested too deeply (limit {d})",
                .{helpers.max_expression_depth},
            );
            return null;
        }
        // A default is folded before any call is made, so no
        // parameter has a value it could read — the fact that keeps
        // signatures from becoming programs (docs/ARGS.md, Refused:
        // call-time defaults).
        if (parameterRead(declaration, written)) |read| {
            try self.fail(
                "luce.sema.const",
                written.span(),
                "a default cannot use {s}: it is folded before any call is made",
                .{read},
            );
            return null;
        }
        const previous_subject = self.fold_subject;
        const previous_name = self.fold_container_name;
        const previous_file = self.fold_container_file;
        const previous_origin = self.fold_container_origin;
        const previous_nesting = self.folding_container;
        self.fold_subject = "a default";
        self.fold_container_name = try std.fmt.allocPrint(
            self.arena,
            "{s}.{s} default",
            .{ declaration.name, parameter.name },
        );
        self.fold_container_file = self.modules[module].file;
        self.fold_container_origin = @intCast(parameter.name_span.start);
        self.folding_container = false;
        defer {
            self.fold_subject = previous_subject;
            self.fold_container_name = previous_name;
            self.fold_container_file = previous_file;
            self.fold_container_origin = previous_origin;
            self.folding_container = previous_nesting;
        }
        const folded = (try constants.fold(self, module, written, resolved)) orelse return null;
        const fitted = constants.fit(folded, resolved) orelse {
            try self.fail("luce.sema.type", parameter.span, "{s} is {s} and its default is {s}", .{
                parameter.name,
                try self.typeName(resolved),
                try self.typeName(folded.value_type),
            });
            return null;
        };
        return fitted;
    }

    /// Fold every field default, eagerly (docs/ARGS.md D2): a default
    /// is evaluated at the declaration, so a bad one is a compile
    /// error whether or not anything ever constructs the struct —
    /// the same promise a parameter default keeps.  Lazy underneath
    /// (`fieldDefault`), because one default may construct a struct
    /// whose own defaults are still pending.
    fn settleFieldDefaults(self: *Analyzer) Error!void {
        for (0..self.struct_decls.items.len) |index| {
            const count = self.struct_decls.items[index].field_defaults.len;
            for (0..count) |field_index| {
                _ = try self.fieldDefault(@intCast(index), field_index);
            }
        }
    }

    /// Whether one collected field declared a default at all — asked
    /// separately from `fieldDefault`, whose null also means "it
    /// failed, and the failure is already reported".
    pub fn fieldHasDefault(self: *const Analyzer, layout_index: u32, field_index: usize) bool {
        if (layout_index >= self.struct_decls.items.len) return false; // a synthesized shape has no declaration
        const info = self.struct_decls.items[layout_index];
        if (field_index >= info.field_defaults.len) return false;
        return info.field_defaults[field_index].expression != null;
    }

    /// The folded default of one field (docs/ARGS.md D8), or null when
    /// there is none or it failed (already reported).  Lazy and
    /// cycle-checked like a file-scope constant, because a default may
    /// construct another struct and lean on *its* defaults in turn.
    pub fn fieldDefault(self: *Analyzer, layout_index: u32, field_index: usize) Error!?TypedConstant {
        if (layout_index >= self.struct_decls.items.len) return null;
        {
            const info = self.struct_decls.items[layout_index];
            if (field_index >= info.field_defaults.len) return null;
        }
        const slot = &self.struct_decls.items[layout_index].field_defaults[field_index];
        const written = slot.expression orelse return null;
        switch (slot.state) {
            .ready => return .{ .value = slot.value, .value_type = slot.value_type },
            .failed => return null,
            .evaluating => {
                const layout = self.structs.items[layout_index];
                try self.fail("luce.sema.const", written.span(), "the default of {s}.{s} depends on itself", .{
                    layout.name,
                    layout.fields[field_index].name,
                });
                slot.state = .failed;
                return null;
            },
            .pending => {},
        }
        slot.state = .evaluating;
        const info = self.struct_decls.items[layout_index];
        // The diagnostic points into the file the struct lives in,
        // whichever module's fold walked into it.
        const previous_scope = self.diagnostics.scope;
        self.diagnostics.scope = self.modules[info.module].file;
        defer self.diagnostics.scope = previous_scope;
        const folded = try self.foldFieldDefault(info.module, layout_index, field_index, written);
        // The list may not move while a fold is in flight (it is
        // temporary-allocated and only appended before folding), but
        // re-find the slot the way `evaluateConstant` does rather than
        // lean on that.
        const settled = &self.struct_decls.items[layout_index].field_defaults[field_index];
        const result = folded orelse {
            settled.state = .failed;
            return null;
        };
        settled.value = result.value;
        settled.value_type = result.value_type;
        settled.state = .ready;
        return result;
    }

    /// The checking half of `fieldDefault`: ownership, depth, the
    /// fold at the field's type, and the landing check.  Null after
    /// reporting.
    fn foldFieldDefault(
        self: *Analyzer,
        module: usize,
        layout_index: u32,
        field_index: usize,
        written: *const ast.Expression,
    ) Error!?TypedConstant {
        const layout = self.structs.items[layout_index];
        const field = layout.fields[field_index];
        // S24: the binding that receives the struct owns its object
        // fields, and a defaulted field is one nobody wrote at the
        // construction site — there is no owner a constant could
        // stand in for (docs/ARGS.md §5).
        if (self.carriesObjects(field.field_type)) {
            try self.fail(
                "luce.sema.own",
                written.span(),
                "{s}.{s} keeps its object, so its default cannot be a shared object [OWNERSHIP.md S21, S24, S46]",
                .{ layout.name, field.name },
            );
            return null;
        }
        if (helpers.deeperThan(written, helpers.max_expression_depth)) {
            try self.fail(
                "luce.sema.nesting",
                written.span(),
                "expression nested too deeply (limit {d})",
                .{helpers.max_expression_depth},
            );
            return null;
        }
        const previous_subject = self.fold_subject;
        self.fold_subject = "a default";
        defer self.fold_subject = previous_subject;
        const folded = (try constants.fold(self, module, written, field.field_type)) orelse return null;
        const fitted = constants.fit(folded, field.field_type) orelse {
            try self.fail("luce.sema.type", written.span(), "{s}.{s} is {s} and its default is {s}", .{
                layout.name,
                field.name,
                try self.typeName(field.field_type),
                try self.typeName(folded.value_type),
            });
            return null;
        };
        return fitted;
    }

    /// Fold every union payload field default, eagerly (docs/UNION.md
    /// D4, docs/ARGS.md D2): a default is evaluated at the
    /// declaration, so a bad one is a compile error whether or not
    /// anything ever constructs the member.
    fn settleVariantDefaults(self: *Analyzer) Error!void {
        for (0..self.variant_decls.items.len) |index| {
            const member_count = self.variant_decls.items[index].member_defaults.len;
            for (0..member_count) |member_index| {
                const field_count = self.variant_decls.items[index].member_defaults[member_index].len;
                for (0..field_count) |field_index| {
                    _ = try self.variantFieldDefault(@intCast(index), member_index, field_index);
                }
            }
        }
    }

    /// Whether one collected member field declared a default at all —
    /// asked separately from `variantFieldDefault`, whose null also
    /// means "it failed, and the failure is already reported".
    pub fn variantFieldHasDefault(
        self: *const Analyzer,
        variant_index: u32,
        member_index: usize,
        field_index: usize,
    ) bool {
        if (variant_index >= self.variant_decls.items.len) return false;
        const info = self.variant_decls.items[variant_index];
        if (member_index >= info.member_defaults.len) return false;
        if (field_index >= info.member_defaults[member_index].len) return false;
        return info.member_defaults[member_index][field_index].expression != null;
    }

    /// The folded default of one union payload field (docs/UNION.md
    /// D4), or null when there is none or it failed (already
    /// reported).  Lazy and cycle-checked like a struct field's,
    /// because a default may construct a struct and lean on *its*
    /// defaults in turn.
    pub fn variantFieldDefault(
        self: *Analyzer,
        variant_index: u32,
        member_index: usize,
        field_index: usize,
    ) Error!?TypedConstant {
        if (!self.variantFieldHasDefault(variant_index, member_index, field_index)) return null;
        const slot = &self.variant_decls.items[variant_index].member_defaults[member_index][field_index];
        const written = slot.expression orelse return null;
        const declared = self.variants.items[variant_index];
        const member = declared.members[member_index];
        const field = member.fields[field_index];
        switch (slot.state) {
            .ready => return .{ .value = slot.value, .value_type = slot.value_type },
            .failed => return null,
            .evaluating => {
                try self.fail("luce.sema.const", written.span(), "the default of {s}.{s}.{s} depends on itself", .{
                    declared.name,
                    member.name,
                    field.name,
                });
                slot.state = .failed;
                return null;
            },
            .pending => {},
        }
        slot.state = .evaluating;
        const info = self.variant_decls.items[variant_index];
        const previous_scope = self.diagnostics.scope;
        self.diagnostics.scope = self.modules[info.module].file;
        defer self.diagnostics.scope = previous_scope;
        const folded = try self.foldVariantFieldDefault(info.module, declared, member, field, written);
        const settled = &self.variant_decls.items[variant_index].member_defaults[member_index][field_index];
        const result = folded orelse {
            settled.state = .failed;
            return null;
        };
        settled.value = result.value;
        settled.value_type = result.value_type;
        settled.state = .ready;
        return result;
    }

    /// The checking half of `variantFieldDefault`: ownership, depth,
    /// the fold at the field's type, and the landing check — S24's
    /// struct-field rule verbatim, because a payload field is a place
    /// that stores (docs/UNION.md).  Null after reporting.
    fn foldVariantFieldDefault(
        self: *Analyzer,
        module: usize,
        declared: types.VariantType,
        member: types.VariantMember,
        field: types.StructField,
        written: *const ast.Expression,
    ) Error!?TypedConstant {
        if (self.carriesObjects(field.field_type)) {
            try self.fail(
                "luce.sema.own",
                written.span(),
                "{s}.{s}.{s} keeps its object, so its default cannot be a shared object [OWNERSHIP.md S21, S24, S46]",
                .{ declared.name, member.name, field.name },
            );
            return null;
        }
        if (helpers.deeperThan(written, helpers.max_expression_depth)) {
            try self.fail(
                "luce.sema.nesting",
                written.span(),
                "expression nested too deeply (limit {d})",
                .{helpers.max_expression_depth},
            );
            return null;
        }
        const previous_subject = self.fold_subject;
        self.fold_subject = "a default";
        defer self.fold_subject = previous_subject;
        const folded = (try constants.fold(self, module, written, field.field_type)) orelse return null;
        const fitted = constants.fit(folded, field.field_type) orelse {
            try self.fail("luce.sema.type", written.span(), "{s}.{s}.{s} is {s} and its default is {s}", .{
                declared.name,
                member.name,
                field.name,
                try self.typeName(field.field_type),
                try self.typeName(folded.value_type),
            });
            return null;
        };
        return fitted;
    }

    /// The first of the declaration's parameter names `expression`
    /// reads — `self` included — or null when it reads none.  A pure
    /// syntactic walk: whether the name means anything else is the
    /// folder's question, asked after this one so the better sentence
    /// wins.
    fn parameterRead(declaration: *const ast.FuncDecl, expression: *const ast.Expression) ?[]const u8 {
        switch (expression.*) {
            .int_literal, .float_literal, .bool_literal, .string_literal, .none_literal => return null,
            .name => |name| {
                for (declaration.parameters) |parameter| {
                    if (std.mem.eql(u8, parameter.name, name.text)) return name.text;
                }
                return null;
            },
            .field => |field| return parameterRead(declaration, field.target),
            .spawn => |worker| return parameterRead(declaration, worker.call),
            .lambda => |written| return parameterRead(declaration, written.body),
            .call => |call| {
                for (call.arguments) |argument| {
                    if (parameterRead(declaration, argument.value)) |read| return read;
                }
                return null;
            },
            .method => |method| {
                if (parameterRead(declaration, method.target)) |read| return read;
                for (method.arguments) |argument| {
                    if (parameterRead(declaration, argument.value)) |read| return read;
                }
                return null;
            },
            .binary => |binary| {
                if (parameterRead(declaration, binary.left)) |read| return read;
                return parameterRead(declaration, binary.right);
            },
            .unary => |unary| return parameterRead(declaration, unary.operand),
            .new_object => |made| {
                for (made.dims) |dim| {
                    if (parameterRead(declaration, dim)) |read| return read;
                }
                return null;
            },
            .list_literal => |list| {
                for (list.elements) |element| {
                    if (parameterRead(declaration, element)) |read| return read;
                }
                return null;
            },
            .map_literal => |map| {
                for (map.entries) |entry| {
                    if (parameterRead(declaration, entry.key)) |read| return read;
                    if (parameterRead(declaration, entry.value)) |read| return read;
                }
                return null;
            },
            .index => |indexed| {
                if (parameterRead(declaration, indexed.target)) |read| return read;
                for (indexed.indices) |position| {
                    if (parameterRead(declaration, position)) |read| return read;
                }
                return null;
            },
            .slice_range => |slice| {
                if (parameterRead(declaration, slice.target)) |read| return read;
                if (slice.start) |start| {
                    if (parameterRead(declaration, start)) |read| return read;
                }
                if (slice.end) |end| {
                    if (parameterRead(declaration, end)) |read| return read;
                }
                return null;
            },
            .give => |verb| return parameterRead(declaration, verb.operand),
            .copy => |verb| return parameterRead(declaration, verb.operand),
            .try_call => |tried| return parameterRead(declaration, tried.operand),
        }
    }

    fn checkEntry(self: *Analyzer) Error!void {
        const index = self.function_names.get("main") orelse {
            try self.fail("luce.sema.main", .{ .start = 0, .end = 0 }, "missing func main():", .{});
            return;
        };
        const info = self.functions.items[index];
        const declaration = info.declaration;
        // Four shapes are legal: `func main():` and
        // `func main(args: list(string)):`, each with or without `-> !`
        // — the mark is how a program says the world can stop it, and
        // loom reports what it raised (docs/FAILURE.md).  A program
        // that never reads a command line says nothing about one, which
        // is why the parameter is optional rather than Java's mandatory
        // ceremony (docs/METHODS.md).
        //
        // The name is free and the type is fixed: `args` is a binding
        // like any other, so there is no misspelling of it to diagnose.
        if (declaration.parameters.len > 1) {
            try self.fail(
                "luce.sema.main",
                declaration.parameters[1].span,
                "main takes at most one parameter, the command line; it has {d}",
                .{declaration.parameters.len},
            );
        } else if (declaration.parameters.len == 1) {
            const parameter = declaration.parameters[0];
            if (parameter.mode == .give) {
                // S13 says `give` appears at both ends, and the entry
                // has one end: the runtime is the caller and there is
                // no call site to say it back.
                try self.fail(
                    "luce.sema.main",
                    parameter.span,
                    "main's parameter takes no verb; the runtime hands the list to main's scope [OWNERSHIP.md S44]",
                    .{},
                );
            } else if (info.parameter_types.len == 1 and
                !self.isCommandLine(info.parameter_types[0]))
            {
                try self.fail(
                    "luce.sema.main",
                    parameter.type_name.span,
                    "main's parameter is the command line and must be list(string); it is {s} here",
                    .{try self.typeName(info.parameter_types[0])},
                );
            }
        }
        if (declaration.returnsSpan()) |written| {
            try self.fail(
                "luce.sema.main",
                written,
                "main returns nothing; use func main():, func main() -> !:, func main(args: list(string)):, or func main(args: list(string)) -> !:",
                .{},
            );
        }
    }

    // -- pass one and a half: the layouts a return shape rides in -------
    //
    // `(double, double)` **is** a two-field product value, so it is
    // lowered as one: `return low, high` is a `struct_make` and
    // `let low, high = …` is two `struct_get`s.  Nothing below stage 4
    // grows a case for multiple results — no MIR instruction, no wire
    // change, no ABI field — and the oracle needs no edit at all,
    // which is why it is the arm that proves this resolved right
    // (docs/RETURNS.md §4).
    //
    // The alternative was multiple result registers on `call` and
    // `ret`.  What kills it is not its size: **LLVM has no multiple
    // returns either**, so it would build in stage 6 a shape stage 8
    // has to collapse back into an aggregate.

    /// Give every function that answers a return shape the synthesized
    /// layout its values travel in.
    ///
    /// **Between `collectFunctions` and any lowering, and that is
    /// load-bearing.**  `Lowering.structs` is a snapshot slice taken
    /// per function and documented as settled before lowering runs, so
    /// appending a layout while a body is in flight would reallocate
    /// the list and leave that slice stale and short.  Every shape a
    /// program can return is known from the signatures alone, so there
    /// is no reason to.
    fn synthesizeShapes(self: *Analyzer) Error!void {
        for (self.functions.items) |*info| {
            if (info.channel.len < 2) continue;
            self.diagnostics.scope = self.modules[info.module].file;
            info.return_type = (try self.internShape(info)) orelse continue;
        }
        self.diagnostics.scope = source_mod.root_file;
    }

    /// The layout for one return shape, interned by the name the shape
    /// is written with.
    ///
    /// **The name is the shape as written** — `(double, double)` — and it
    /// is unforgeable from source: a struct name is an identifier,
    /// qualified with a module prefix, so nothing a program can declare
    /// collides with a name containing `(`.  It reads correctly in
    /// `luce ir` and it reads correctly if it ever reaches a
    /// diagnostic through `types.typeName`.  Two functions with the
    /// same shape intern to one layout, as heap type shapes already do.
    fn internShape(self: *Analyzer, info: *const FunctionDeclInfo) Error!?Type {
        const name = try self.writtenResults(info);
        for (self.structs.items, 0..) |layout, index| {
            if (std.mem.eql(u8, layout.name, name)) return .{ .strukt = @intCast(index) };
        }

        var fields: std.ArrayList(types.StructField) = .empty;
        defer fields.deinit(self.arena);
        var values: u32 = 0;
        var carries = false;
        for (info.channel, 0..) |result, position| {
            try fields.append(self.arena, .{
                .name = try std.fmt.allocPrint(self.arena, "field{d}", .{position}),
                .field_type = result,
            });
            values +|= self.valueCount(result);
            if (self.carriesObjects(result)) carries = true;
        }
        // The same bound every other width in the language takes, and
        // for the same reason: `zeroOf` emits one instruction per
        // counted leaf.  A signature that approaches it has other
        // problems, but the bound must be the same bound and not a
        // second number.
        if (values > helpers.max_struct_values) {
            try self.fail(
                "luce.sema.return",
                info.declaration.returnsSpan() orelse info.declaration.span,
                "{s} answers {d} values in all, past the limit of {d}",
                .{ info.declaration.name, values, helpers.max_struct_values },
            );
            return null;
        }

        const index: u32 = @intCast(self.structs.items.len);
        try self.structs.append(self.arena, .{
            .name = name,
            .fields = try fields.toOwnedSlice(self.arena),
        });
        // `carriesObjects` and `valueCount` index this table directly,
        // and the ownership walk asks both of a returned shape — so a
        // layout without a shape entry is an out-of-bounds read the
        // first time `lowerReturn` asks whether it carries objects.
        try self.struct_shapes.append(self.temporary, .{ .carries = carries, .values = values });
        return .{ .strukt = index };
    }

    /// What a function answers, as a reader wrote it: `long` for one
    /// value, `(long, long)` for a shape, `None` for nothing.  Also the
    /// synthesized layout's name, so the two can never disagree.
    pub fn writtenResults(self: *Analyzer, info: *const FunctionDeclInfo) Error![]const u8 {
        if (info.channel.len == 0) return "None";
        if (info.channel.len == 1) return self.typeName(info.channel[0]);
        var written: std.ArrayList(u8) = .empty;
        errdefer written.deinit(self.arena);
        try written.append(self.arena, '(');
        for (info.channel, 0..) |result, position| {
            if (position != 0) try written.appendSlice(self.arena, ", ");
            try written.appendSlice(self.arena, try self.typeName(result));
        }
        try written.append(self.arena, ')');
        return written.toOwnedSlice(self.arena);
    }

    /// The layout behind a return shape, or null for every other type
    /// — including every struct a program declared.
    ///
    /// Told apart by the name, which is the shape as written and
    /// therefore **unforgeable from source**: a struct name is an
    /// identifier, qualified with a module prefix, so nothing a
    /// program can declare begins with `(`.  That is what lets a
    /// return shape be a struct underneath and still not be a type a
    /// program can name (docs/RETURNS.md).
    pub fn returnShapeOf(self: *const Analyzer, of: Type) ?types.StructLayout {
        if (of != .strukt) return null;
        const layout = self.structs.items[of.strukt];
        if (layout.name.len == 0 or layout.name[0] != '(') return null;
        return layout;
    }

    /// Whether a type is the one shape the entry's parameter may have.
    fn isCommandLine(self: *const Analyzer, of: Type) bool {
        const descriptor = self.heapOf(of) orelse return false;
        return descriptor == .list and descriptor.list == .string;
    }

    pub fn typeName(self: *Analyzer, of: Type) Error![]const u8 {
        return types.typeName(
            self.arena,
            self.structs.items,
            self.heap_types.items,
            self.enums.items,
            self.variants.items,
            self.signatures.items,
            of,
        );
    }

    /// Where a fully-qualified name is already declared, whichever of
    /// the three tables holds it — or null when none does.
    pub fn firstDeclarationOf(self: *Analyzer, qualified: []const u8) Error!?[]const u8 {
        if (self.function_names.get(qualified)) |index| {
            const info = self.functions.items[index];
            return try self.declaredAt(self.modules[info.module].file, info.declaration.name_span);
        }
        if (self.struct_names.get(qualified)) |index| {
            const info = self.struct_decls.items[index];
            return try self.declaredAt(self.modules[info.module].file, info.declaration.name_span);
        }
        if (self.enum_names.get(qualified)) |index| {
            const info = self.enum_decls.items[index];
            return try self.declaredAt(self.modules[info.module].file, info.declaration.name_span);
        }
        if (self.variant_names.get(qualified)) |index| {
            const info = self.variant_decls.items[index];
            return try self.declaredAt(self.modules[info.module].file, info.declaration.name_span);
        }
        if (self.constant_names.get(qualified)) |index| {
            const info = self.constant_infos.items[index];
            return try self.declaredAt(self.modules[info.module].file, info.declaration.name_span);
        }
        return null;
    }

    /// Where a name was already declared, for a message about the
    /// second one: " on line 7", or " in geo.luc on line 7" when the
    /// first is in another file.
    ///
    /// Where the other one is, is the single most useful thing a
    /// duplicate diagnostic can carry, and none of the four spellings
    /// of it carried anything at all.
    pub fn declaredAt(self: *Analyzer, file: source_mod.FileId, span: Span) Error![]const u8 {
        const at = self.diagnostics.sources.place(file, span.start);
        if (file == self.diagnostics.scope) {
            return std.fmt.allocPrint(self.arena, " on line {d}", .{at.line});
        }
        return std.fmt.allocPrint(self.arena, " in {s} on line {d}", .{
            self.diagnostics.sources.pathOf(file),
            at.line,
        });
    }

    // Function bodies ------------------------------------------------------

    fn lowerFunction(self: *Analyzer, info: FunctionDeclInfo) Error!mir.build.Lowering {
        self.diagnostics.scope = self.modules[info.module].file;
        defer self.diagnostics.scope = source_mod.root_file;
        var builder: builder_mod.FunctionBuilder = .{
            .analyzer = self,
            .module = info.module,
            .prefix = self.modules[info.module].prefix,
            .results = info.results,
            .static_member = info.enclosing != null and info.receiver == .not,
            .enclosing_locals = info.enclosing_locals,
            .code = .{
                .arena = self.arena,
                .pool = self.pool,
                .structs = self.structs.items,
                .enums = self.enums.items,
                .variants = self.variants.items,
                .name = info.name,
                .parameter_count = @intCast(info.parameter_types.len),
                .return_type = info.return_type,
                .fallible = info.fallible,
                .file = self.modules[info.module].file,
                .origin = @intCast(info.declaration.span.start),
            },
        };
        defer builder.deinitScratch();

        try builder.code.openBlock();
        try builder.pushScope();

        const hidden: usize = if (info.receiver == .not) 0 else 1;
        if (info.receiver != .not) {
            _ = try builder.declareReceiver(
                info.parameter_types[0],
                info.receiver == .writes,
                info.declaration.name_span,
            );
        }

        for (info.declaration.parameters, 0..) |parameter, written_index| {
            const index = written_index + hidden;
            if (index >= info.parameter_types.len) break;
            const parameter_type = info.parameter_types[index];
            // The entry's `args` arrived owning its list: the runtime
            // built it and nobody else names it, so `main`'s scope
            // frees it on the way out, exactly as a `give` parameter's
            // scope does (OWNERSHIP.md S44, S15).
            const owns = info.parameter_modes[index] == .give or info.is_entry;
            const class: OwnershipClass = if (owns) .owned else .borrow_param;
            // A parameter borrows its caller's storage, whichever
            // way the object goes: the caller's binding outlives
            // the call and gives the bytes back itself
            // (docs/STRINGS.md).
            const local = (try builder.declareLocalAs(
                parameter.name,
                parameter_type,
                false,
                class,
                .borrows,
                parameter.name_span,
            )) orelse continue;
            builder.setRoot(local, if (owns) .mutable else .unknown);
            // An owning parameter is an owned binding like any other
            // (S15): take the object over from the caller on entry.
            if (owns) {
                const value = try builder.code.load(local);
                try builder.code.bind(local, value);
            }
        }

        try builder.lowerBlock(info.declaration.body);
        try builder.emitScopeEnd();
        builder.popScope();

        // A typed function must return on every path.  The span is the
        // written return type rather than the `func` line: in a long
        // function that is the claim being broken, and it is what the
        // reader has to change if they meant something else.
        if (info.results.len != 0 and !helpers.returnsOnAllPaths(info.declaration.body)) {
            const at = info.declaration.returnsSpan() orelse info.declaration.span;
            try self.fail(
                "luce.sema.return",
                at,
                "{s} must return {s} on every path, and some path reaches the end of its body without returning",
                .{ info.declaration.name, try self.writtenResults(&info) },
            );
        }
        // Everything from here — sealing the open blocks, freezing the
        // block lists, turning the recorded source offsets into lines
        // and columns, naming the file — is stage 6's, and runs when
        // `mir.build` closes the tape.
        return builder.code;
    }
};
