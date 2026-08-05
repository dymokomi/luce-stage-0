//! Luce semantic analysis — pass one, and the drive of pass two.
//!
//! Declaration collection first: struct layouts and their shapes,
//! function signatures, file-scope constants folded, the selected
//! entry.  Then `builder.zig` walks every function body, checking it
//! and recording what it decides on stage 6's tape.  The type checker
//! knows Luce types and nothing else; nothing about any backend
//! appears here.
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
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");
const mir = @import("../06_mir.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");
// The folder answers what a run would answer, so where a judgment has
// one implementation in `libluce_rt` the folder calls it rather than
// keeping a second copy that could drift (docs/NUMERICS.md §5).
const operators = @import("../runtime/operators.zig");

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const Type = types.Type;
const StructLayout = types.StructLayout;
const Diagnostics = diagnostics_mod.Diagnostics;
const Register = mir.Register;
const BlockId = mir.BlockId;
const LocalId = mir.LocalId;

// The stage's shared vocabulary, spelled unqualified here because this
// file is one of its two speakers (`04_semantics/context.zig`).
const Error = context.Error;
const Analyzed = context.Analyzed;
const ModuleTree = context.ModuleTree;
const FunctionDeclInfo = context.FunctionDeclInfo;
const StructDeclInfo = context.StructDeclInfo;
const StructShape = context.StructShape;
const ConstantValue = context.ConstantValue;
const TypedConstant = context.TypedConstant;
const ConstantInfo = context.ConstantInfo;
const OwnershipClass = context.OwnershipClass;
const isReserved = context.isReserved;
const integer_range_message = context.integer_range_message;
const float_range_message = context.float_range_message;
const mismatched_operands_message = context.mismatched_operands_message;
const namespace_has_no_fields_message = context.namespace_has_no_fields_message;
const duplicate_field_message = context.duplicate_field_message;
const missing_field_message = context.missing_field_message;

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
    functions: std.ArrayList(FunctionDeclInfo) = .empty,
    function_names: std.StringHashMapUnmanaged(u32) = .empty,
    /// The program's string constants.  A `Program` field, so the
    /// pool and its interning live in stage 6; this stage fills it as
    /// literals type-check.
    pool: *mir.build.ConstantPool,
    constant_infos: std.ArrayList(ConstantInfo) = .empty,
    constant_names: std.StringHashMapUnmanaged(u32) = .empty,

    fn deinitScratch(self: *Analyzer) void {
        self.struct_decls.deinit(self.temporary);
        self.struct_shapes.deinit(self.temporary);
        self.struct_names.deinit(self.temporary);
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
        try self.collectStructs();
        try self.collectConstants();
        try self.collectFunctions();
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
        const table = [_]struct { name: []const u8, resolved: Type }{
            .{ .name = "Bool", .resolved = .boolean },
            .{ .name = "Int", .resolved = .int },
            .{ .name = "Float", .resolved = .float },
            .{ .name = "String", .resolved = .string },
        };
        for (table) |entry| {
            if (std.mem.eql(u8, written.name, entry.name)) {
                if (written.arguments.len != 0 or written.wildcards != 0) {
                    try self.fail("luce.sema.type", written.span, "{s} takes no type arguments", .{written.name});
                    return null;
                }
                return entry.resolved;
            }
        }
        if (std.mem.eql(u8, written.name, "List")) {
            if (written.arguments.len != 1 or written.wildcards != 0) {
                try self.fail("luce.sema.type", written.span, "List takes one element type: List(Int)", .{});
                return null;
            }
            const element = (try self.resolveType(module, written.arguments[0])) orelse return null;
            if (try self.refuseOptionalPart(element, written.arguments[0], "list element")) return null;
            return try self.internHeapType(.{ .list = element });
        }
        if (std.mem.eql(u8, written.name, "Map")) {
            if (written.arguments.len != 2 or written.wildcards != 0) {
                try self.fail("luce.sema.type", written.span, "Map takes key and value types: Map(String, Int)", .{});
                return null;
            }
            const key = (try self.resolveType(module, written.arguments[0])) orelse return null;
            if (key != .int and key != .string) {
                try self.fail("luce.sema.type", written.arguments[0].span, "Map keys are Int or String", .{});
                return null;
            }
            const value = (try self.resolveType(module, written.arguments[1])) orelse return null;
            if (try self.refuseOptionalPart(value, written.arguments[1], "map value")) return null;
            return try self.internHeapType(.{ .map = .{ .key = key, .value = value } });
        }
        if (std.mem.eql(u8, written.name, "Array")) {
            if (written.arguments.len != 1 or written.wildcards == 0 or written.wildcards > 4) {
                try self.fail(
                    "luce.sema.type",
                    written.span,
                    "Array spells element and shape: Array(Int, _) up to Array(Int, _, _, _, _)",
                    .{},
                );
                return null;
            }
            const element = (try self.resolveType(module, written.arguments[0])) orelse return null;
            if (try self.refuseOptionalPart(element, written.arguments[0], "array element")) return null;
            return try self.internHeapType(.{ .array = .{ .element = element, .rank = written.wildcards } });
        }
        if (std.mem.eql(u8, written.name, "Builder")) {
            if (written.arguments.len != 0 or written.wildcards != 0) {
                try self.fail("luce.sema.type", written.span, "Builder takes no type arguments", .{});
                return null;
            }
            return try self.internHeapType(.builder);
        }
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
            if (self.struct_names.get(written.name)) |index| return .{ .strukt = index };
            try self.failUnknownType(module, written);
            return null;
        }
        const local = try self.qualify(self.modules[module].prefix, written.name);
        if (self.struct_names.get(local)) |index| return .{ .strukt = index };
        try self.failUnknownType(module, written);
        return null;
    }

    /// Report a written type name that names nothing, offering the
    /// closest of the builtin types and the structs this module can
    /// see.  A misremembered `Str` or `Bolean` is the commonest of all
    /// type errors and the cheapest to answer well.
    fn failUnknownType(self: *Analyzer, module: usize, written: ast.TypeName) Error!void {
        const builtin_types = [_][]const u8{
            "Bool", "Int", "Float", "String", "List", "Map", "Array", "Builder",
        };
        const prefix = self.modules[module].prefix;
        var suggestion = helpers.Suggestion.init(written.name);
        suggestion.offerAll(&builtin_types);
        var keys = self.struct_names.keyIterator();
        while (keys.next()) |key| {
            if (prefix.len == 0) {
                suggestion.offer(key.*);
            } else if (key.len > prefix.len + 1 and
                std.mem.startsWith(u8, key.*, prefix) and key.*[prefix.len] == '.')
            {
                suggestion.offer(key.*[prefix.len + 1 ..]);
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
            // A `List(T)?` holding an object owns it exactly as the
            // unwrapped type would; holding `none` owns nothing (S43),
            // and every ownership walk already no-ops on absence.
            .optional => |payload| self.carriesObjects(payload.asType()),
            else => false,
        };
    }

    /// True for types that carry *storage* — a String's bytes, a
    /// struct's field run — as opposed to objects (docs/STRINGS.md).
    ///
    /// Deliberately not `carriesObjects`, and deliberately not wired to
    /// it.  This predicate drives release emission and nothing else:
    /// widening `carriesObjects` to Strings would make `xs.append(name)`
    /// demand `give name` under S21, which is a language change.  A
    /// String takes no verbs (S32) and still gets reclaimed, which is
    /// the whole point.
    pub fn ownsStorage(self: *const Analyzer, of: Type) bool {
        return switch (of) {
            // A struct owns its field run whatever is in it, so this
            // needs no shape lookup — an all-Int struct still has a
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
                const qualified = try self.qualify(module.prefix, declaration.name);
                if (self.struct_names.get(qualified)) |first| {
                    const info = self.struct_decls.items[first];
                    try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate struct {s}; the first is{s}", .{
                        declaration.name,
                        try self.declaredAt(self.modules[info.module].file, info.declaration.name_span),
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
            for (declaration.fields) |field| {
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
                try fields.append(self.arena, .{
                    .name = try self.arena.dupe(u8, field.name),
                    .field_type = field_type,
                });
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
            "struct {s} always holds more than {d} values; bulk data belongs in a List, Map, or Array, which is one reference",
            .{ layout.name, helpers.max_struct_values },
        );
        try self.fail(
            "luce.sema.struct",
            self.fieldSpan(index, found.name),
            "struct {s} always holds more than {d} values once its nested structs are counted; {s} is {s}, which is {d} of them on its own; write {s}: {s}? to hold those only when they are there, or move bulk data into a List, Map, or Array, which is one reference",
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

    // File-scope constants --------------------------------------------------

    /// Register every module's top-level `let` constants, then fold
    /// each one so every error reports even when nothing uses it.
    // -- pass one: file-scope constants, folded ---------------------------

    fn collectConstants(self: *Analyzer) Error!void {
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
        for (0..self.constant_infos.items.len) |index| {
            const module = self.constant_infos.items[index].module;
            self.diagnostics.scope = self.modules[module].file;
            _ = try self.evaluateConstant(@intCast(index));
        }
        self.diagnostics.scope = source_mod.root_file;
    }

    /// Fold one constant, lazily and cycle-checked.  Null after a
    /// reported error.
    fn evaluateConstant(self: *Analyzer, index: u32) Error!?TypedConstant {
        const info = &self.constant_infos.items[index];
        switch (info.state) {
            .ready => return .{ .value = info.value, .value_type = info.value_type },
            .failed => return null,
            .evaluating => {
                try self.fail(
                    "luce.sema.const",
                    info.declaration.span,
                    "constant {s} depends on itself",
                    .{info.declaration.name},
                );
                info.state = .failed;
                return null;
            },
            .pending => {},
        }
        info.state = .evaluating;
        const declaration = info.declaration;
        const module = info.module;
        if (helpers.deeperThan(declaration.value, helpers.max_expression_depth)) {
            try self.fail(
                "luce.sema.nesting",
                declaration.span,
                "expression nested too deeply (limit {d})",
                .{helpers.max_expression_depth},
            );
            self.constant_infos.items[index].state = .failed;
            return null;
        }
        const folded = try self.foldConstant(module, declaration.value);
        // The map may have grown while folding dependencies; re-find.
        const settled = &self.constant_infos.items[index];
        const result = folded orelse {
            settled.state = .failed;
            return null;
        };
        if (declaration.annotation) |written| {
            const expected = (try self.resolveType(module, written)) orelse {
                settled.state = .failed;
                return null;
            };
            if (!result.value_type.eql(expected)) {
                try self.fail("luce.sema.type", declaration.span, "{s} declared {s} but its value is {s}", .{
                    declaration.name,
                    try self.typeName(expected),
                    try self.typeName(result.value_type),
                });
                settled.state = .failed;
                return null;
            }
        }
        settled.value = result.value;
        settled.value_type = result.value_type;
        settled.state = .ready;
        return result;
    }

    fn constantError(self: *Analyzer, span: Span, comptime format: []const u8, arguments: anytype) Error!?TypedConstant {
        try self.fail("luce.sema.const", span, format, arguments);
        return null;
    }

    /// Fold a constant expression: literals, other constants
    /// (`pi`, `geo.pi`, struct-constant fields), arithmetic and
    /// comparisons, string concatenation, `Int`/`Float` conversions,
    /// and value-struct construction.  Objects and calls are not
    /// constants.
    fn foldConstant(self: *Analyzer, module: usize, expression: *const ast.Expression) Error!?TypedConstant {
        switch (expression.*) {
            .int_literal => |literal| {
                const parsed = helpers.parseIntLiteral(literal.text, false) orelse {
                    return self.constantError(literal.span, "{s}", .{integer_range_message});
                };
                return .{ .value = .{ .int = parsed }, .value_type = .int };
            },
            .float_literal => |literal| {
                const parsed = helpers.parseFloatLiteral(literal.text) orelse {
                    return self.constantError(literal.span, "{s}", .{float_range_message});
                };
                return .{ .value = .{ .float = parsed }, .value_type = .float };
            },
            .bool_literal => |literal| {
                return .{ .value = .{ .boolean = literal.value }, .value_type = .boolean };
            },
            .string_literal => |literal| {
                return .{ .value = .{ .string = literal.decoded }, .value_type = .string };
            },
            // `none` has no type of its own — the place it is written
            // into supplies one — and a file-scope constant is folded
            // before anything can supply it.
            .none_literal => |literal| {
                return self.constantError(literal.span, "none is not a constant; a constant is a value that is there", .{});
            },
            .name => |name| {
                const qualified = try self.qualify(self.modules[module].prefix, name.text);
                if (self.constant_names.get(qualified)) |index| {
                    return self.evaluateConstant(index);
                }
                return self.constantError(name.span, "unknown name {s} in a constant (constants may use literals and other constants)", .{name.text});
            },
            .field => |field| {
                // geo.pi — an imported module's constant...
                if (field.target.* == .name) {
                    const head = field.target.name.text;
                    if (self.importsModule(module, head)) {
                        const joined = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ head, field.name });
                        if (self.constant_names.get(joined)) |index| {
                            return self.evaluateConstant(index);
                        }
                        return self.constantError(field.span, "{s} has no constant {s}", .{ head, field.name });
                    }
                }
                // ...or a field of a struct constant.
                const target = (try self.foldConstant(module, field.target)) orelse return null;
                if (target.value != .strukt) {
                    return self.constantError(field.span, "{s} has no fields here", .{try self.typeName(target.value_type)});
                }
                const layout = self.structs.items[target.value.strukt.layout];
                const field_index = layout.findField(field.name) orelse {
                    return self.constantError(field.span, "{s} has no field {s}", .{ layout.name, field.name });
                };
                return .{
                    .value = target.value.strukt.fields[field_index],
                    .value_type = layout.fields[field_index].field_type,
                };
            },
            .unary => |unary| {
                // -9223372036854775808 is one literal, not a negated
                // one: the sign folds in before the range is checked.
                if (unary.op == .negate and unary.operand.* == .int_literal) {
                    const literal = unary.operand.int_literal;
                    const parsed = helpers.parseIntLiteral(literal.text, true) orelse {
                        return self.constantError(unary.span, "{s}", .{integer_range_message});
                    };
                    return .{ .value = .{ .int = parsed }, .value_type = .int };
                }
                const operand = (try self.foldConstant(module, unary.operand)) orelse return null;
                switch (unary.op) {
                    .negate => switch (operand.value) {
                        .int => |value| {
                            if (value == std.math.minInt(i64)) {
                                return self.constantError(unary.span, "constant arithmetic overflows", .{});
                            }
                            return .{ .value = .{ .int = -value }, .value_type = .int };
                        },
                        .float => |value| return .{ .value = .{ .float = -value }, .value_type = .float },
                        else => return self.constantError(unary.span, "cannot negate {s}", .{try self.typeName(operand.value_type)}),
                    },
                    .logic_not => switch (operand.value) {
                        .boolean => |value| return .{ .value = .{ .boolean = !value }, .value_type = .boolean },
                        else => return self.constantError(unary.span, "not needs a Bool", .{}),
                    },
                }
            },
            .binary => |binary| return self.foldBinary(module, binary),
            .call => |call| {
                if (std.mem.eql(u8, call.callee, "Int") or
                    std.mem.eql(u8, call.callee, "Float") or
                    std.mem.eql(u8, call.callee, "String"))
                {
                    if (call.arguments.len != 1 or call.arguments[0].name != null) {
                        return self.constantError(call.span, "{s}(value) takes one argument", .{call.callee});
                    }
                    const operand = (try self.foldConstant(module, call.arguments[0].value)) orelse return null;
                    return self.foldConvert(call, operand);
                }
                // ord is the one builtin that folds, so a character
                // can be written as one: `ord("(")` where another
                // language would need character literal syntax.
                if (std.mem.eql(u8, call.callee, "ord")) {
                    if (call.arguments.len != 1 or call.arguments[0].name != null) {
                        return self.constantError(call.span, "ord(text) takes one argument", .{});
                    }
                    const operand = (try self.foldConstant(module, call.arguments[0].value)) orelse return null;
                    if (operand.value != .string) {
                        return self.constantError(call.span, "ord takes a String, not {s}", .{
                            try self.typeName(operand.value_type),
                        });
                    }
                    const codepoint = helpers.ordOfLiteral(operand.value.string) orelse {
                        return self.constantError(call.span, "ord has no codepoint to read from an empty String", .{});
                    };
                    return .{ .value = .{ .int = codepoint }, .value_type = .int };
                }
                const qualified = try self.qualify(self.modules[module].prefix, call.callee);
                if (self.struct_names.get(qualified)) |layout_index| {
                    return self.foldConstruct(module, call.arguments, call.span, layout_index);
                }
                return self.constantError(call.span, "constants fold at compile time; calls are not constant", .{});
            },
            .method => |method| {
                // module.Struct(...) construction reaches imports.
                if (method.target.* == .name) {
                    const head = method.target.name.text;
                    if (self.importsModule(module, head)) {
                        const joined = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ head, method.name });
                        if (self.struct_names.get(joined)) |layout_index| {
                            return self.foldConstruct(module, method.arguments, method.span, layout_index);
                        }
                    }
                }
                return self.constantError(method.span, "constants fold at compile time; calls are not constant", .{});
            },
            .new_object, .list_literal, .slice_range, .index => {
                return self.constantError(expression.span(), "constants are values; objects cannot be file-scope [OWNERSHIP.md S35]", .{});
            },
            .give, .copy => {
                return self.constantError(expression.span(), "constants are values and never take verbs [OWNERSHIP.md S32]", .{});
            },
            .try_call => {
                return self.constantError(expression.span(), "a constant is folded at compile time and nothing can fail there; try belongs in a function", .{});
            },
        }
    }

    fn foldConvert(self: *Analyzer, call: ast.Call, operand: TypedConstant) Error!?TypedConstant {
        if (std.mem.eql(u8, call.callee, "String")) {
            // The same text a run would print, spelled by the same
            // rules — but from a constant, so it is arena-owned here
            // rather than made by the runtime.
            // `{d}` on both, which is exactly what `runtime/text.zig`
            // writes: a Float's text is Zig's Ryū-derived shortest
            // representation that round-trips, and a folded constant
            // has to be the same bytes a run would produce.
            const printed: []const u8 = switch (operand.value) {
                .int => |held| try std.fmt.allocPrint(self.arena, "{d}", .{held}),
                .float => |held| try std.fmt.allocPrint(self.arena, "{d}", .{held}),
                .boolean => |held| if (held) "true" else "false",
                .string => |held| held,
                else => return self.constantError(call.span, "String() converts Int, Float, Bool, or String", .{}),
            };
            return .{ .value = .{ .string = printed }, .value_type = .string };
        }
        const to_int = std.mem.eql(u8, call.callee, "Int");
        if (to_int) {
            switch (operand.value) {
                .int => return operand,
                .float => |value| {
                    // The same guard as `runtime/operators.zig` and
                    // `08_llvm/lower.zig`, value for value: a
                    // conversion that disagrees at the boundary is a
                    // different language.  And the same rounding —
                    // half away from zero (docs/NUMERICS.md §7),
                    // through the runtime's own function so there is
                    // one of it.
                    const rounded = operators.roundHalfAway(value);
                    if (std.math.isNan(rounded) or
                        rounded < -9223372036854775808.0 or
                        rounded >= 9223372036854775808.0)
                    {
                        return self.constantError(call.span, "constant conversion out of range", .{});
                    }
                    return .{ .value = .{ .int = @intFromFloat(rounded) }, .value_type = .int };
                },
                else => return self.constantError(call.span, "Int() converts Float", .{}),
            }
        }
        switch (operand.value) {
            .float => return operand,
            .int => |value| return .{ .value = .{ .float = @floatFromInt(value) }, .value_type = .float },
            else => return self.constantError(call.span, "Float() converts Int", .{}),
        }
    }

    fn foldConstruct(
        self: *Analyzer,
        module: usize,
        call_arguments: []const ast.Argument,
        span: Span,
        layout_index: u32,
    ) Error!?TypedConstant {
        const layout = self.structs.items[layout_index];
        const result_type: Type = .{ .strukt = layout_index };
        if (self.carriesObjects(result_type)) {
            return self.constantError(span, "{s} carries objects; constants are values only [OWNERSHIP.md S35]", .{layout.name});
        }
        if (layout.fields.len == 0) {
            return self.constantError(span, namespace_has_no_fields_message, .{layout.name});
        }
        const fields = try self.arena.alloc(ConstantValue, layout.fields.len);
        const seen = try self.temporary.alloc(bool, layout.fields.len);
        defer self.temporary.free(seen);
        @memset(seen, false);
        for (call_arguments) |argument| {
            const name = argument.name orelse {
                return self.constantError(argument.span, "{s} is built with named fields: {s}(field = ...)", .{ layout.name, layout.name });
            };
            const field_index = layout.findField(name) orelse {
                return self.constantError(argument.span, "{s} has no field {s}", .{ layout.name, name });
            };
            if (seen[field_index]) {
                return self.constantError(argument.span, duplicate_field_message, .{name});
            }
            const value = (try self.foldConstant(module, argument.value)) orelse return null;
            if (!value.value_type.eql(layout.fields[field_index].field_type)) {
                return self.constantError(argument.span, "{s}.{s} is {s}, got {s}", .{
                    layout.name,
                    name,
                    try self.typeName(layout.fields[field_index].field_type),
                    try self.typeName(value.value_type),
                });
            }
            seen[field_index] = true;
            fields[field_index] = value.value;
        }
        for (seen) |given| {
            if (given) continue;
            var missing: std.ArrayList(u8) = .empty;
            defer missing.deinit(self.temporary);
            try context.writeMissingFields(&missing, self.temporary, layout, seen);
            return self.constantError(span, missing_field_message, .{ layout.name, missing.items });
        }
        return .{
            .value = .{ .strukt = .{ .layout = layout_index, .fields = fields } },
            .value_type = result_type,
        };
    }

    fn foldBinary(self: *Analyzer, module: usize, binary: ast.Binary) Error!?TypedConstant {
        // A constant is a value that is there, so there is nothing for
        // a fallback to be a fallback *for*.
        if (binary.op == .coalesce) {
            return self.constantError(binary.span, "else has nothing to do in a constant: a constant is always there", .{});
        }
        // Nor is there anything for a catch to catch: a constant is
        // folded at compile time and no call is made at all.
        if (binary.op == .catch_error) {
            return self.constantError(binary.span, "catch has nothing to do in a constant: nothing is called there", .{});
        }
        var left = (try self.foldConstant(module, binary.left)) orelse return null;
        // Short-circuit folds without evaluating the other side's
        // side effects — there are none, so plain evaluation is fine.
        var right = (try self.foldConstant(module, binary.right)) orelse return null;

        // Numbers that mix, folded (docs/NUMERICS.md).  A constant has
        // to reach the same answer a run would, so arithmetic widens
        // the Int here too and comparison stays exact — the comparison
        // calls the runtime's own function rather than a second copy
        // of it, because two implementations of one judgment is how
        // they come to disagree.
        if ((left.value_type == .int and right.value_type == .float) or
            (left.value_type == .float and right.value_type == .int))
        {
            if (helpers.comparisonOf(binary.op)) |written| {
                const int_first = left.value_type == .int;
                return .{
                    .value = .{ .boolean = operators.compareIntFloat(
                        if (int_first) written else written.mirrored(),
                        if (int_first) left.value.int else right.value.int,
                        if (int_first) right.value.float else left.value.float,
                    ) },
                    .value_type = .boolean,
                };
            }
            // The widened number is computed *before* the assignment,
            // because the struct literal writes into `left` field by
            // field: reading `left.value.int` inside it would read a
            // union whose active field the same expression had just
            // changed.
            if (left.value_type == .int) {
                const widened: f64 = @floatFromInt(left.value.int);
                left = .{ .value = .{ .float = widened }, .value_type = .float };
            } else {
                const widened: f64 = @floatFromInt(right.value.int);
                right = .{ .value = .{ .float = widened }, .value_type = .float };
            }
        }

        // `/` is real division and answers a Float whatever it
        // divides, so two Int constants widen here too — and `1 / 0`
        // folds to `inf` rather than refusing (docs/NUMERICS.md §2).
        if (binary.op == .divide and left.value_type == .int and right.value_type == .int) {
            const numerator: f64 = @floatFromInt(left.value.int);
            const denominator: f64 = @floatFromInt(right.value.int);
            left = .{ .value = .{ .float = numerator }, .value_type = .float };
            right = .{ .value = .{ .float = denominator }, .value_type = .float };
        }

        if (!left.value_type.eql(right.value_type)) {
            return self.constantError(binary.span, mismatched_operands_message, .{
                context.operatorText(binary.op),
                try self.typeName(left.value_type),
                try self.typeName(right.value_type),
            });
        }
        switch (binary.op) {
            .logic_and, .logic_or => {
                if (left.value != .boolean) return self.constantError(binary.span, "and/or need Bool operands", .{});
                const folded = if (binary.op == .logic_and)
                    left.value.boolean and right.value.boolean
                else
                    left.value.boolean or right.value.boolean;
                return .{ .value = .{ .boolean = folded }, .value_type = .boolean };
            },
            .add, .subtract, .multiply, .divide, .floor_divide, .modulo => switch (left.value) {
                .int => |a| {
                    const b = right.value.int;
                    const folded: i64 = switch (binary.op) {
                        .add => blk: {
                            const result = @addWithOverflow(a, b);
                            if (result[1] != 0) return self.constantError(binary.span, "constant arithmetic overflows", .{});
                            break :blk result[0];
                        },
                        .subtract => blk: {
                            const result = @subWithOverflow(a, b);
                            if (result[1] != 0) return self.constantError(binary.span, "constant arithmetic overflows", .{});
                            break :blk result[0];
                        },
                        .multiply => blk: {
                            const result = @mulWithOverflow(a, b);
                            if (result[1] != 0) return self.constantError(binary.span, "constant arithmetic overflows", .{});
                            break :blk result[0];
                        },
                        // `/` widened both sides before this switch,
                        // so an integer one cannot arrive here
                        // (docs/NUMERICS.md §2).
                        .divide => unreachable,
                        // `//` and `%` floor together
                        // (docs/NUMERICS.md §3); the folder answers
                        // what a run answers.
                        .floor_divide => blk: {
                            if (b == 0) return self.constantError(binary.span, "constant division by zero", .{});
                            if (a == std.math.minInt(i64) and b == -1) {
                                return self.constantError(binary.span, "constant arithmetic overflows", .{});
                            }
                            break :blk @divFloor(a, b);
                        },
                        .modulo => blk: {
                            if (b == 0) return self.constantError(binary.span, "constant division by zero", .{});
                            if (a == std.math.minInt(i64) and b == -1) {
                                return self.constantError(binary.span, "constant arithmetic overflows", .{});
                            }
                            break :blk @mod(a, b);
                        },
                        else => unreachable,
                    };
                    return .{ .value = .{ .int = folded }, .value_type = .int };
                },
                .float => |a| {
                    const b = right.value.float;
                    const folded: f64 = switch (binary.op) {
                        .add => a + b,
                        .subtract => a - b,
                        .multiply => a * b,
                        .divide => a / b,
                        .floor_divide => @floor(a / b),
                        .modulo => @mod(a, b),
                        else => unreachable,
                    };
                    return .{ .value = .{ .float = folded }, .value_type = .float };
                },
                .string => |a| {
                    if (binary.op != .add) {
                        return self.constantError(binary.span, "String supports + only", .{});
                    }
                    const joined = try std.mem.concat(self.arena, u8, &.{ a, right.value.string });
                    return .{ .value = .{ .string = joined }, .value_type = .string };
                },
                else => return self.constantError(binary.span, "{s} does not support this operator", .{
                    try self.typeName(left.value_type),
                }),
            },
            .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => {
                const ordering = binary.op != .equal and binary.op != .not_equal;
                const folded: bool = switch (left.value) {
                    .int => |a| helpers.compareOrder(binary.op, a, right.value.int),
                    .float => |a| helpers.compareOrder(binary.op, a, right.value.float),
                    .string => |a| blk: {
                        const order = std.mem.order(u8, a, right.value.string);
                        break :blk switch (binary.op) {
                            .equal => order == .eq,
                            .not_equal => order != .eq,
                            .less => order == .lt,
                            .less_equal => order != .gt,
                            .greater => order == .gt,
                            .greater_equal => order != .lt,
                            else => unreachable,
                        };
                    },
                    .boolean => |a| blk: {
                        if (ordering) return self.constantError(binary.span, "Bool has no ordering", .{});
                        const same = a == right.value.boolean;
                        break :blk if (binary.op == .equal) same else !same;
                    },
                    .strukt => return self.constantError(binary.span, "struct constants have no comparison", .{}),
                };
                return .{ .value = .{ .boolean = folded }, .value_type = .boolean };
            },
            .coalesce, .catch_error => unreachable, // answered above
        }
    }

    // -- pass one: function signatures, and the entry ---------------------

    fn collectFunctions(self: *Analyzer) Error!void {
        for (self.modules, 0..) |module, module_index| {
            self.diagnostics.scope = module.file;
            for (module.tree.functions) |*declaration| {
                const qualified = try self.qualify(module.prefix, declaration.name);
                try self.collectFunction(declaration, qualified, module_index, true);
            }
            for (module.tree.structs) |*declaration| {
                for (declaration.functions) |*function| {
                    const member = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{
                        declaration.name,
                        function.name,
                    });
                    const qualified = try self.qualify(module.prefix, member);
                    try self.collectFunction(function, qualified, module_index, false);
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
    ) Error!void {
        const in_root = self.modules[module].prefix.len == 0;
        if (isReserved(declaration.name)) {
            try self.fail("luce.sema.reserved", declaration.name_span, "{s} is a reserved name", .{declaration.name});
            return;
        }
        if (self.function_names.contains(name) or
            self.constant_names.contains(name) or
            (top_level and self.struct_names.contains(name)))
        {
            try self.fail("luce.sema.duplicate", declaration.name_span, "duplicate name {s}; the first is{s}", .{
                declaration.name,
                (try self.firstDeclarationOf(name)) orelse "",
            });
            return;
        }

        const is_entry = top_level and in_root and std.mem.eql(u8, declaration.name, "main");
        var parameter_types: std.ArrayList(Type) = .empty;
        defer parameter_types.deinit(self.arena);
        var parameter_modes: std.ArrayList(ast.ParameterMode) = .empty;
        defer parameter_modes.deinit(self.arena);
        // The entry's parameter is collected like every other one: it
        // is the command line, it has a type, and `checkEntry` below
        // is what says which type it has to be (OWNERSHIP.md S44).
        for (declaration.parameters) |parameter| {
            const resolved = (try self.resolveType(module, parameter.type_name)) orelse continue;
            if (parameter.mode == .give and !self.carriesObjects(resolved)) {
                try self.fail(
                    "luce.sema.own",
                    parameter.span,
                    "give applies to objects (List, Map, Array, Builder, object-carrying structs), not values [OWNERSHIP.md S32]",
                    .{},
                );
                continue;
            }
            try parameter_types.append(self.arena, resolved);
            try parameter_modes.append(self.arena, parameter.mode);
        }
        var return_type: Type = .none;
        if (declaration.return_type) |written| {
            return_type = (try self.resolveType(module, written)) orelse .none;
        }

        const index: u32 = @intCast(self.functions.items.len);
        try self.function_names.put(self.temporary, name, index);
        try self.functions.append(self.arena, .{
            .declaration = declaration,
            .name = try self.arena.dupe(u8, name),
            .module = module,
            .parameter_types = try parameter_types.toOwnedSlice(self.arena),
            .parameter_modes = try parameter_modes.toOwnedSlice(self.arena),
            .return_type = return_type,
            .fallible = declaration.fallible,
            .is_entry = is_entry,
        });
    }

    fn checkEntry(self: *Analyzer) Error!void {
        const index = self.function_names.get("main") orelse {
            try self.fail("luce.sema.main", .{ .start = 0, .end = 0 }, "missing func main():", .{});
            return;
        };
        const info = self.functions.items[index];
        const declaration = info.declaration;
        // Four shapes are legal: `func main():` and
        // `func main(args: List(String)):`, each with or without `-> !`
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
                    "main's parameter is the command line and must be List(String); it is {s} here",
                    .{try self.typeName(info.parameter_types[0])},
                );
            }
        }
        if (declaration.return_type) |written| {
            try self.fail(
                "luce.sema.main",
                written.span,
                "main returns nothing; the entry is func main(): or func main() -> !: when the world can stop it",
                .{},
            );
        }
    }

    /// Whether a type is the one shape the entry's parameter may have.
    fn isCommandLine(self: *const Analyzer, of: Type) bool {
        const descriptor = self.heapOf(of) orelse return false;
        return descriptor == .list and descriptor.list == .string;
    }

    pub fn typeName(self: *Analyzer, of: Type) Error![]const u8 {
        return types.typeName(self.arena, self.structs.items, self.heap_types.items, of);
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
            .code = .{
                .arena = self.arena,
                .pool = self.pool,
                .structs = self.structs.items,
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
            const local = (try builder.declareLocalAs(
                parameter.name,
                parameter_type,
                false,
                class,
                .borrows,
                parameter.name_span,
            )) orelse continue;
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
        if (info.return_type != .none and !helpers.returnsOnAllPaths(info.declaration.body)) {
            const at = if (info.declaration.return_type) |written| written.span else info.declaration.span;
            try self.fail(
                "luce.sema.return",
                at,
                "{s} must return {s} on every path, and some path reaches the end of its body without returning",
                .{ info.declaration.name, try self.typeName(info.return_type) },
            );
        }
        // Everything from here — sealing the open blocks, freezing the
        // block lists, turning the recorded source offsets into lines
        // and columns, naming the file — is stage 6's, and runs when
        // `mir.build` closes the tape.
        return builder.code;
    }
};
