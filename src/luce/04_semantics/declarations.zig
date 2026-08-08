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
    struct_names: std.StringHashMapUnmanaged(u32) = .empty,
    /// The declared enums, in declaration order (docs/ENUMS.md).  They
    /// share the type-name space with structs — a program that declares
    /// both `struct Method` and `enum Method` has declared one name
    /// twice — so `firstDeclarationOf` reads both.
    enums: std.ArrayList(types.EnumType) = .empty,
    enum_decls: std.ArrayList(context.EnumDeclInfo) = .empty,
    enum_names: std.StringHashMapUnmanaged(u32) = .empty,
    functions: std.ArrayList(FunctionDeclInfo) = .empty,
    function_names: std.StringHashMapUnmanaged(u32) = .empty,
    /// The program's string constants.  A `Program` field, so the
    /// pool and its interning live in stage 6; this stage fills it as
    /// literals type-check.
    pool: *mir.build.ConstantPool,
    constant_infos: std.ArrayList(ConstantInfo) = .empty,
    constant_names: std.StringHashMapUnmanaged(u32) = .empty,

    /// What the fold underway is *for*, when it is not a file-scope
    /// `let`: "a default" while a parameter or field default folds
    /// (docs/ARGS.md D2), null otherwise.  The folder's answer never
    /// changes with it — only the sentence a refusal opens with, so a
    /// reader who wrote `start: long = g()` is told about defaults and
    /// not about a `let` they never wrote.
    fold_subject: ?[]const u8 = null,

    fn deinitScratch(self: *Analyzer) void {
        self.struct_decls.deinit(self.temporary);
        self.struct_shapes.deinit(self.temporary);
        self.struct_names.deinit(self.temporary);
        self.enum_decls.deinit(self.temporary);
        self.enum_names.deinit(self.temporary);
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
        // Enum *names* first: a struct field, a parameter or a
        // constant's annotation may name one, and a name has to be
        // resolvable before any type is (docs/ENUMS.md).  Their member
        // *values* are folded after the constant names are registered,
        // because `= base + 1` may name a constant.
        try self.collectEnumNames();
        try self.collectStructs();
        try self.registerConstants();
        try self.settleEnumMembers();
        try constants.foldAll(self);
        try self.settleFieldDefaults();
        try self.collectFunctions();
        try self.synthesizeShapes();
        if (self.diagnostics.hasErrors()) return null;

        var lowered: std.ArrayList(mir.build.Lowering) = .empty;
        defer lowered.deinit(self.arena);
        for (self.functions.items) |info| {
            try lowered.append(self.arena, try self.lowerFunction(info));
        }
        if (self.diagnostics.hasErrors()) return null;

        const entry_index = self.function_names.get("main") orelse return null;

        return .{
            .structs = try self.structs.toOwnedSlice(self.arena),
            .heap_types = try self.heap_types.toOwnedSlice(self.arena),
            .enums = try self.enums.toOwnedSlice(self.arena),
            .functions = try lowered.toOwnedSlice(self.arena),
            .constants = try self.pool.items.toOwnedSlice(self.arena),
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

    /// The name a refusal calls `module` — the prefix a program
    /// writes in front of the dot.  Only ever read for a declaring
    /// module in a cross-module refusal, and the root module cannot be
    /// imported, so the answer is never empty where it is used.
    pub fn moduleName(self: *const Analyzer, module: usize) []const u8 {
        return self.modules[module].prefix;
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
        const prefix = self.modules[module].prefix;
        return if (prefix.len == 0) "this file" else prefix;
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
            .heap => |index| switch (self.heap_types.items[index]) {
                .list => |element| self.privateMentioned(element),
                // A map key is long or string, never a struct.
                .map => |pair| self.privateMentioned(pair.value),
                .array => |shape| self.privateMentioned(shape.element),
                .builder, .file => null,
                .task => |work| self.privateMentioned(work.result),
            },
            .optional => |payload| self.privateMentioned(payload.asType()),
            else => null,
        };
    }

    /// True when `module` imports `name`.
    pub fn importsModule(self: *const Analyzer, module: usize, name: []const u8) bool {
        for (self.modules[module].tree.imports) |imported| {
            if (std.mem.eql(u8, imported.name, name)) return true;
        }
        return false;
    }

    /// The import that would make `name` reachable, spelled the way
    /// the author has to write it: `std.math` for the library,
    /// `geo` for a file beside the program.
    ///
    /// A module already in the program answers for itself — a
    /// sibling `math.luc` that another file imports is reached with
    /// `import math`, even though `std.math` exists too.  Only when
    /// nothing is loaded under the name does the library get to
    /// claim it.
    pub fn importSpelling(self: *Analyzer, name: []const u8) Error![]const u8 {
        for (self.modules) |module| {
            if (!std.mem.eql(u8, module.prefix, name)) continue;
            const kind = self.diagnostics.sources.at(module.file).?.kind;
            if (kind != .standard) return name;
            return self.qualify(source_mod.standard_namespace, name);
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
                    try self.fail("luce.sema.type", written.arguments[0].span, "map keys are long or string", .{});
                    return null;
                }
                const value = (try self.resolveType(module, written.arguments[1])) orelse return null;
                if (try self.refuseOptionalPart(value, written.arguments[1], "map value")) return null;
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
            if (!self.importsModule(module, head)) {
                try self.fail("luce.sema.import", written.span, "unknown module {s}; import {s} to use its types", .{ head, try self.importSpelling(head) });
                return null;
            }
            if (self.struct_names.get(written.name)) |index| {
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
            if (self.enum_names.get(written.name)) |index| {
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
            try self.failUnknownType(module, written);
            return null;
        }
        const local = try self.qualify(self.modules[module].prefix, written.name);
        if (self.struct_names.get(local)) |index| return .{ .strukt = index };
        if (self.enum_names.get(local)) |index| return self.enumType(index);
        try self.failUnknownType(module, written);
        return null;
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
        for ([_]*const std.StringHashMapUnmanaged(u32){ &self.struct_names, &self.enum_names }) |declared| {
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

    pub fn heapOf(self: *const Analyzer, of: Type) ?types.HeapType {
        if (of != .heap) return null;
        return self.heap_types.items[of.heap];
    }

    /// True for types the ownership rules apply to: heap objects and
    /// structs transitively containing them (S27's "object-carrying").
    /// An array read: `collectStructs` settles every struct's shape
    /// once the layouts are known, and struct cycles are rejected
    /// before that.
    pub fn carriesObjects(self: *const Analyzer, of: Type) bool {
        return switch (of) {
            .heap => true,
            .strukt => |layout_index| self.struct_shapes.items[layout_index].carries,
            // A `list(T)?` holding an object owns it exactly as the
            // unwrapped type would; holding `none` owns nothing (S43),
            // and every ownership walk already no-ops on absence.
            .optional => |payload| self.carriesObjects(payload.asType()),
            else => false,
        };
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
            // run to give back.
            .string, .strukt => true,
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
            else => 1,
        };
    }

    // -- pass one: enums, names then values -------------------------------

    /// Register every declared enum's name and backing width
    /// (docs/ENUMS.md D1, D2).  The members are collected here too,
    /// with their names and their *positions*; the values are folded by
    /// `settleEnumMembers` below, once every name in the program
    /// exists.
    fn collectEnumNames(self: *Analyzer) Error!void {
        for (self.modules, 0..) |module, module_index| {
            self.diagnostics.scope = module.file;
            for (module.tree.enums) |*declaration| {
                if (isReserved(declaration.name)) {
                    try self.fail("luce.sema.reserved", declaration.name_span, "{s} is a reserved name", .{declaration.name});
                    continue;
                }
                if (types.builtinNamed(declaration.name) != null) {
                    try self.fail(
                        "luce.sema.reserved",
                        declaration.name_span,
                        "{s} is a builtin type; an enum of your own takes a name of its own",
                        .{declaration.name},
                    );
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
                // **Whichever was written first is the first.**  Enums
                // are collected before structs — a struct field may name
                // one — so a struct of the same name is still invisible
                // here; the one this file *reads* first is decided by
                // where the two stand, not by which table filled first.
                // A struct above this enum reports here; a struct below
                // it lets the enum register and reports there.
                if (structDeclaredAbove(module.tree.*, declaration)) |first| {
                    try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                        declaration.name,
                        try self.declaredAt(module.file, first.name_span),
                    });
                    continue;
                }
                // The width, before the members: it is what says which
                // of them fit, and the default is `int` (D2).
                var backing: types.Type.EnumRef.Backing = .int;
                if (declaration.backing) |written| {
                    const resolved = (try self.resolveType(module_index, written)) orelse continue;
                    backing = types.Type.EnumRef.Backing.of(resolved) orelse {
                        try self.fail(
                            "luce.sema.enum",
                            written.span,
                            "an enum is stored at an integer width: byte, short, int, or long — not {s}",
                            .{try self.typeName(resolved)},
                        );
                        continue;
                    };
                }
                if (declaration.members.len == 0) {
                    try self.fail(
                        "luce.sema.enum",
                        declaration.span,
                        "enum {s} names no members; an enum is the set of names it declares",
                        .{declaration.name},
                    );
                    continue;
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
                    // A function of the enum may not wear a member's
                    // name: `Method.stored` would mean two things, and
                    // the head-names-a-declaration path answers one.
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
                if (members.items.len == 0) continue; // every member was refused
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
        }
        self.diagnostics.scope = source_mod.root_file;
    }

    /// The struct of this module that takes `declaration`'s name and
    /// stands above it in the file, or null.
    fn structDeclaredAbove(tree: ast.Program, declaration: *const ast.EnumDecl) ?*const ast.StructDecl {
        for (tree.structs) |*strukt| {
            if (!std.mem.eql(u8, strukt.name, declaration.name)) continue;
            if (strukt.name_span.start < declaration.name_span.start) return strukt;
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
        // Imports first: names must be usable and free of collisions.
        for (self.modules, 0..) |module, module_index| {
            self.diagnostics.scope = module.file;
            for (module.tree.imports) |imported| {
                if (isReserved(imported.name) or std.mem.eql(u8, imported.name, "evaluate")) {
                    try self.fail("luce.sema.reserved", imported.span, "{s} is a reserved name", .{imported.name});
                }
                for (module.tree.structs) |declaration| {
                    if (std.mem.eql(u8, declaration.name, imported.name)) {
                        try self.fail("luce.sema.duplicate", imported.span, "import {s} collides with a struct of the same name", .{imported.name});
                    }
                }
                for (module.tree.enums) |declaration| {
                    if (std.mem.eql(u8, declaration.name, imported.name)) {
                        try self.fail("luce.sema.duplicate", imported.span, "import {s} collides with an enum of the same name", .{imported.name});
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

        // A struct containing itself (directly or through another
        // struct) would have no finite value; and what every struct
        // carries and costs is settled in the same walk.
        const cyclic = try self.temporary.alloc(bool, self.structs.items.len);
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
        self.diagnostics.scope = source_mod.root_file;
    }

    /// One step of a containment chain: a layout, and the field of it
    /// that holds the next layout along.
    const ChainStep = struct { layout: u32, field: u32 };

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
    /// breadth-first over struct fields and confined to layouts that
    /// are on a cycle.  The caret goes on the field that opens it,
    /// never the `struct` keyword, because the field is the line that
    /// gets edited — and `T?` is the edit, because a value that may be
    /// absent is where the recursion stops (docs/LANGUAGE.md).
    fn reportStructCycles(self: *Analyzer, cyclic: []const bool) Error!void {
        const count = self.structs.items.len;
        const unvisited = std.math.maxInt(u32);

        const reported = try self.temporary.alloc(bool, count);
        defer self.temporary.free(reported);
        @memset(reported, false);
        const came_from = try self.temporary.alloc(u32, count);
        defer self.temporary.free(came_from);
        const came_via = try self.temporary.alloc(u32, count);
        defer self.temporary.free(came_via);

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
            var closing_layout: u32 = unvisited;
            var closing_field: u32 = unvisited;
            var head: usize = 0;
            search: while (head < queue.items.len) : (head += 1) {
                const layout = queue.items[head];
                for (self.structs.items[layout].fields, 0..) |field, field_index| {
                    if (field.field_type != .strukt) continue;
                    const held = field.field_type.strukt;
                    if (held == start) {
                        closing_layout = layout;
                        closing_field = @intCast(field_index);
                        break :search;
                    }
                    if (!cyclic[held] or came_from[held] != unvisited) continue;
                    came_from[held] = layout;
                    came_via[held] = @intCast(field_index);
                    try queue.append(self.temporary, held);
                }
            }
            // `start` is marked cyclic, so an edge back to it exists.
            if (closing_layout == unvisited) continue;

            // Walk the parent links back to `start`, then turn the
            // chain around so it reads the way the source does.
            chain.clearRetainingCapacity();
            try chain.append(self.temporary, .{ .layout = closing_layout, .field = closing_field });
            var cursor = closing_layout;
            while (cursor != start) {
                const parent = came_from[cursor];
                try chain.append(self.temporary, .{ .layout = parent, .field = came_via[cursor] });
                cursor = parent;
            }
            std.mem.reverse(ChainStep, chain.items);
            for (chain.items) |step| reported[step.layout] = true;

            written.clearRetainingCapacity();
            for (chain.items, 0..) |step, position| {
                if (position != 0) {
                    try written.appendSlice(self.temporary, ", ");
                    if (position + 1 == chain.items.len) try written.appendSlice(self.temporary, "and ");
                }
                const layout = self.structs.items[step.layout];
                const field = layout.fields[step.field];
                try written.print(self.temporary, "{s}.{s} is {s}", .{
                    layout.name,
                    field.name,
                    try self.typeName(field.field_type),
                });
            }

            const opening = chain.items[0];
            const opening_field = self.structs.items[opening.layout].fields[opening.field];
            const info = self.struct_decls.items[opening.layout];
            self.diagnostics.scope = self.modules[info.module].file;
            try self.fail(
                "luce.sema.struct",
                self.fieldSpan(opening.layout, opening_field.name),
                "struct {s} contains itself: {s}; a struct is a value, so write {s}: {s}? to let the chain end at absence",
                .{
                    self.structs.items[start].name,
                    written.items,
                    opening_field.name,
                    try self.typeName(opening_field.field_type),
                },
            );
        }
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

    /// One pass over the struct containment graph: mark every layout
    /// that lies on a cycle, and fill in the shape of every layout
    /// that does not.
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
        const count = self.structs.items.len;
        try self.struct_shapes.appendNTimes(self.temporary, .{ .values = 1 }, count);
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
        const Step = struct { layout: u32, field: u32 };
        var path: std.ArrayList(Step) = .empty;
        defer path.deinit(self.temporary);

        var next_order: u32 = 0;
        for (0..count) |root| {
            if (order[root] != unvisited) continue;
            order[root] = next_order;
            lowest[root] = next_order;
            next_order += 1;
            open[root] = true;
            try pending.append(self.temporary, @intCast(root));
            try path.append(self.temporary, .{ .layout = @intCast(root), .field = 0 });

            while (path.items.len != 0) {
                // `step` points into `path`, which the descent below
                // may grow: everything read through it is read before
                // that append, and nothing is read after.
                const step = &path.items[path.items.len - 1];
                const layout = step.layout;
                const fields = self.structs.items[layout].fields;
                if (step.field < fields.len) {
                    const field_type = fields[step.field].field_type;
                    step.field += 1;
                    if (field_type != .strukt) continue;
                    const held = field_type.strukt;
                    if (held == layout) cyclic[layout] = true;
                    if (order[held] == unvisited) {
                        order[held] = next_order;
                        lowest[held] = next_order;
                        next_order += 1;
                        open[held] = true;
                        try pending.append(self.temporary, held);
                        try path.append(self.temporary, .{ .layout = held, .field = 0 });
                    } else if (open[held]) {
                        lowest[layout] = @min(lowest[layout], order[held]);
                    }
                    continue;
                }

                // Every field visited: this layout closes.  Its
                // struct fields are either closed (their shapes are
                // final) or still open, which means a cycle the
                // component check below is about to catch.
                self.struct_shapes.items[layout] = self.sumShape(layout);
                _ = path.pop();
                if (path.items.len != 0) {
                    const parent = path.items[path.items.len - 1].layout;
                    lowest[parent] = @min(lowest[parent], lowest[layout]);
                }
                if (lowest[layout] != order[layout]) continue;

                // The root of a component: everything pushed at or
                // after it is a member.  More than one member means
                // they hold each other, so none has a finite value.
                var first = pending.items.len;
                while (pending.items[first - 1] != layout) first -= 1;
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
            if (on_cycle) self.struct_shapes.items[index] = .{ .values = 1 };
        }
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

    // -- pass one: file-scope constants -----------------------------------
    //
    // Only the registration is here; folding one is `constants.zig`'s,
    // and `run` calls it right after this so an error in a constant
    // nothing reads still reports.

    /// Register every module's top-level `let` constants under their
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
        }
        self.diagnostics.scope = source_mod.root_file;
        try self.checkEntry();
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
        // The entry's parameter is collected like every other one: it
        // is the command line, it has a type, and `checkEntry` below
        // is what says which type it has to be (OWNERSHIP.md S44).
        var receiver: ast.Receiver = .not;
        for (declaration.parameters) |parameter| {
            // `self` is parameter zero of a method, and its type is the
            // struct around it — there is nothing written to resolve.
            // Stage 3 has already refused one anywhere but first and
            // one with an annotation, so a receiver reaching here is in
            // the only place it can be (docs/METHODS.md).
            if (parameter.receiver != .not) {
                const owner = enclosing orelse {
                    try self.fail(
                        "luce.sema.self",
                        parameter.span,
                        "self is only a parameter of a function declared inside a struct or an enum",
                        .{},
                    );
                    continue;
                };
                const receiver_type = owner.asType();
                // A `var self` method writes its receiver back to
                // the receiver's place, and that write is a pure value
                // store — which it can only be if the struct carries
                // no object handles.  Not a restriction invented for
                // the feature: it is where S17 and S28 already put the
                // corpus, and a struct that *does* carry objects
                // mutates through its fields from a plain `self` (S38),
                // which needs no write-back at all (docs/METHODS.md).
                if (parameter.receiver == .writes and self.carriesObjects(receiver_type)) {
                    try self.fail(
                        "luce.sema.self",
                        parameter.span,
                        "{s} carries objects, so it cannot be written back; take self and mutate through the field, or write a namespace function [OWNERSHIP.md S17, S28]",
                        .{try self.typeName(receiver_type)},
                    );
                    continue;
                }
                receiver = parameter.receiver;
                try parameter_types.append(self.arena, receiver_type);
                try parameter_modes.append(self.arena, .borrow);
                try parameter_defaults.append(self.arena, null);
                continue;
            }
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
                    "give applies to objects (list, map, array, builder, object-carrying structs), not values [OWNERSHIP.md S32]",
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
        // A `var self` method's receiver is result zero: its results
        // are `[receiver] ++ declared`, and they travel in one
        // synthesized layout, so there is no receiver mechanism
        // separate from the return mechanism (docs/RETURNS.md §5).
        var channel: std.ArrayList(Type) = .empty;
        defer channel.deinit(self.arena);
        if (receiver == .writes) try channel.append(self.arena, enclosing.?.asType());
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

    /// Fold one parameter default at the parameter's own type
    /// (docs/ARGS.md D2): evaluated once, at the declaration, by the
    /// folder that already folds file-scope `let` — and materialised
    /// at each call site as the constant register the same literal
    /// would have produced written out, so the lowered program is
    /// byte-identical to the one with the argument written.  Null
    /// after reporting.
    fn foldDefault(
        self: *Analyzer,
        module: usize,
        declaration: *const ast.FuncDecl,
        parameter: ast.Parameter,
        resolved: Type,
        written: *const ast.Expression,
    ) Error!?TypedConstant {
        // A give parameter takes ownership of an object and an object
        // is never a constant — two rules that already refuse this,
        // handed the one sentence they imply (docs/ARGS.md §5, D12).
        if (parameter.mode == .give) {
            try self.fail(
                "luce.sema.own",
                parameter.span,
                "a give parameter takes ownership of an object, and an object is never a default [OWNERSHIP.md S13, S32]",
                .{},
            );
            return null;
        }
        if (self.carriesObjects(resolved)) {
            try self.fail("luce.sema.const", parameter.span, "a default is a constant, and an object is not one", .{});
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
        self.fold_subject = "a default";
        defer self.fold_subject = previous_subject;
        var folded = (try constants.fold(self, module, written, resolved)) orelse return null;
        if (folded.value_type.widensTo(resolved)) folded = constants.widen(folded, resolved);
        if (!folded.value_type.eql(resolved)) {
            try self.fail("luce.sema.type", parameter.span, "{s} is {s} and its default is {s}", .{
                parameter.name,
                try self.typeName(resolved),
                try self.typeName(folded.value_type),
            });
            return null;
        }
        return folded;
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
                "{s}.{s} keeps its object, and an object is never a default [OWNERSHIP.md S21, S24]",
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
        var folded = (try constants.fold(self, module, written, field.field_type)) orelse return null;
        if (folded.value_type.widensTo(field.field_type)) folded = constants.widen(folded, field.field_type);
        if (!folded.value_type.eql(field.field_type)) {
            try self.fail("luce.sema.type", written.span(), "{s}.{s} is {s} and its default is {s}", .{
                layout.name,
                field.name,
                try self.typeName(field.field_type),
                try self.typeName(folded.value_type),
            });
            return null;
        }
        return folded;
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
                "main returns nothing; the entry is func main(): or func main() -> !: when the world can stop it",
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
            .channel = info.channel,
            .writes_receiver = info.receiver == .writes,
            .code = .{
                .arena = self.arena,
                .pool = self.pool,
                .structs = self.structs.items,
                .enums = self.enums.items,
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

        for (info.declaration.parameters, 0..) |parameter, index| {
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
            // Parameters are immutable, with one exception: `var self`
            // says the method may reassign its receiver, and `self =
            // Point(x = 0.0, y = 0.0)` inside one means what it says
            // (docs/METHODS.md).
            const writes_back = parameter.receiver == .writes;
            // And that exception decides the *storage* too.  Every
            // other parameter borrows its caller's — the caller's
            // binding outlives the call and gives the bytes back
            // itself (docs/STRINGS.md).  A `var self` receiver is
            // written to, and every write frees what it replaced, so
            // the slot has to own what it holds or the first
            // `self.x = …` would give the caller's run back.  It takes
            // a copy on entry, which is exactly the `var moved =
            // state` the corpus writes by hand at every mutation site
            // it has (docs/METHODS.md).
            const local = (try builder.declareLocalAs(
                parameter.name,
                parameter_type,
                writes_back,
                class,
                if (writes_back) .owns else .borrows,
                parameter.name_span,
            )) orelse continue;
            if (writes_back) {
                const arrived = try builder.code.load(local);
                try builder.code.store(local, try builder.code.ownStorage(arrived));
            }
            // An owning parameter is an owned binding like any other
            // (S15): take the object over from the caller on entry.
            if (owns) {
                const value = try builder.code.load(local);
                try builder.code.bind(local, value);
            }
        }

        try builder.lowerBlock(info.declaration.body);
        // `func step(var self):` names no result, so its body ends
        // without a `return` — but its receiver still has to leave.
        // One implicit `return self` at the end, which is the same
        // instruction an explicit one emits (docs/RETURNS.md §5).
        if (info.receiver == .writes and info.results.len == 0) {
            try builder.returnReceiver();
        }
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
