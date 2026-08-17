//! Luce semantic analysis — pass one, and the drive of pass two.
//!
//! Declaration collection first: struct layouts and their shapes, enum
//! tables, function signatures, file-scope constants, the selected
//! entry.  Then `builder.zig` walks every function body, checking it
//! and recording what it decides as a typed tree (hir.zig) — and
//! once the whole program has checked clean, `hir.lower` lowers each
//! recorded body onto stage 6's tape, driven from here because only
//! the analyzer holds the settled tables it reads.  The type checker
//! knows Luce types and nothing else; nothing about any backend
//! appears here.
//!
//! **This file is pass one's spine, and its concerns are its
//! siblings.**  `Analyzer` itself lives here — the tables the whole
//! stage reads, the report cap every diagnostic goes through, the
//! order the collectors run in, and the drive of pass two — and each
//! concern that could be named on its own is a file beside it,
//! holding free functions over `*Analyzer`:
//!
//!   naming.zig     — what a declaration is called, where it was
//!                    written, and who may see it.
//!   resolve.zig    — a written type name to a `Type`, and the
//!                    interning behind the shapes it mints.
//!   shapes.zig     — what a type carries, how wide it is, and the
//!                    cycle walk that settles both.
//!   layouts.zig    — the declared type tables: enums, unions,
//!                    structs.
//!   signatures.zig — the function table, the entry, and the layout a
//!                    return shape rides in.
//!   defaults.zig   — the folded defaults of a parameter, a field,
//!                    and a union payload field.
//!   receiver.zig   — whether a method writes its implicit `self`.
//!
//! A file boundary in Zig is a privacy boundary, so the price of that
//! is stated plainly: a sibling takes the analyzer and reads its
//! tables honestly, and `pub` in this family means *visible to stage
//! 4's own files*, nothing wider.  What stayed a method is what reads
//! one table and nothing else — `fail`, `typeName`, `heapOf`,
//! `signatureOf`, `enumType` — because those are what the `Analyzer`
//! *is* rather than a job it does.
//!
//! **Collection, not evaluation.**  A constant, an enum member's value
//! and a default are all *folded* by `constants.zig`, which this
//! family calls at four points and does not otherwise contain: it
//! registers the names, and the evaluator turns an expression into a
//! value.  The two are separate because the folding order is not the
//! collection order — an enum member's value may name a constant and a
//! constant may name an enum member, so every name has to exist before
//! either fold runs (docs/ENUMS.md D8).  Registration is the one
//! collector still on this spine, because it is three lines of table
//! and the sentence above is the whole of its interface.
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
const source_mod = @import("../source.zig");
const helpers = @import("helpers.zig");
const builder_mod = @import("builder.zig");
const context = @import("context.zig");

// Compile-time evaluation: the folder every constant, enum value and
// default goes through (`constants.zig`).
const constants = @import("constants.zig");
const types = @import("../support/types.zig");
const mir = @import("../mir.zig");

// Pass one's own concerns, each a file of free functions over the
// `Analyzer` below.
const defaults = @import("defaults.zig");
const aliases = @import("aliases.zig");
const layouts = @import("layouts.zig");
const naming = @import("naming.zig");
const receiver = @import("receiver.zig");
const resolve = @import("resolve.zig");
const shapes = @import("shapes.zig");
const signatures = @import("signatures.zig");
const interfaces = @import("interfaces.zig");
const closures = @import("closures.zig");
const initializers = @import("initializers.zig");

// The check/lower seam's far side (hir.zig): the walk below checks
// and records the typed tree, and `hir.lower` is the one emission —
// it lowers each recorded body onto stage 6's tape.
const hir = @import("../hir.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const Type = types.Type;
const StructLayout = types.StructLayout;
const Diagnostics = diagnostics_mod.Diagnostics;

// The stage's shared vocabulary, spelled unqualified here because this
// file is one of its two speakers (`semantics/context.zig`).
const Error = context.Error;
const Analyzed = context.Analyzed;
const ModuleTree = context.ModuleTree;
const FunctionDeclInfo = context.FunctionDeclInfo;
const StructDeclInfo = context.StructDeclInfo;
const StructShape = context.StructShape;
const InterfaceDeclInfo = context.InterfaceDeclInfo;
const InterfaceConformance = context.InterfaceConformance;
const AliasDeclInfo = context.AliasDeclInfo;
const ConstantInfo = context.ConstantInfo;
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
/// reads the tables below — through the few methods on it, and through
/// the sibling files that take it as their first argument; everything
/// that *fills* those tables runs once, before any body is checked.
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
    /// Transparent source-level type names.  Their resolved `Type` is cached
    /// here only during analysis; no alias identity crosses into HIR or MIR.
    alias_names: std.StringHashMapUnmanaged(u32) = .empty,
    alias_decls: std.ArrayList(AliasDeclInfo) = .empty,
    alias_stack: std.ArrayList(u32) = .empty,
    struct_names: std.StringHashMapUnmanaged(u32) = .empty,
    /// Interfaces use the same written type namespace as structs, but keep
    /// a separate map so their hidden dispatch layouts cannot be constructed
    /// or mistaken for ordinary field-bearing structs.
    interface_names: std.StringHashMapUnmanaged(u32) = .empty,
    interface_decls: std.ArrayList(InterfaceDeclInfo) = .empty,
    conformances: std.ArrayList(InterfaceConformance) = .empty,
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
    /// Which row the runtime starts, once `entry.settle` has decided:
    /// the declared `main`, or the one the compiler wrote for `luce
    /// test`.  Null until then, and on a program that has no entry at
    /// all — which is a diagnosed program, so the walk stops before
    /// anything reads this.
    entry_function: ?u32 = null,
    standard_specializations: std.ArrayList(signatures.StandardSpecialization) = .empty,
    /// Compiler-generated ARC cell layouts used by mutable captures.
    closure_cells: std.ArrayList(context.ClosureCellLayout) = .empty,
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
    /// reader who wrote `start: i64 = g()` is told about defaults and
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
        self.alias_names.deinit(self.temporary);
        self.alias_decls.deinit(self.temporary);
        self.alias_stack.deinit(self.temporary);
        self.struct_names.deinit(self.temporary);
        self.interface_names.deinit(self.temporary);
        self.interface_decls.deinit(self.temporary);
        self.conformances.deinit(self.temporary);
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
        try aliases.collectDeclarations(self);
        try layouts.collectTypeNames(self);
        try layouts.collectStructs(self);
        try layouts.settleVariantMembers(self);
        try shapes.settleTypeShapes(self);
        try self.registerConstants();
        try layouts.settleEnumMembers(self);
        try constants.foldAll(self);
        try defaults.settleFieldDefaults(self);
        try defaults.settleVariantDefaults(self);
        try signatures.collectFunctions(self);
        try receiver.inferReceiverWrites(self);
        try signatures.synthesizeShapes(self);
        try interfaces.synthesizeShapes(self);
        try interfaces.settleConformances(self);
        if (self.diagnostics.hasErrors()) return null;

        // The check/lower seam (hir.zig): every body is checked and
        // recorded first, and only a program with no diagnostics is
        // lowered — so `hir.lower` never sees a gapped tree.
        //
        // **By index, because the list grows while it is walked.**  A
        // lambda becomes a top-level function the moment its landing
        // site is checked (docs/FUNCTIONS.md D2), so checking function
        // K can append function K+n — and that one is checked in its
        // turn, by this loop, with no second pass and no fix-up.
        var bodies: std.ArrayList(?hir.nodes.Body) = .empty;
        defer bodies.deinit(self.temporary);
        var at: usize = 0;
        while (at < self.functions.items.len) : (at += 1) {
            try bodies.append(self.temporary, try self.checkFunction(self.functions.items[at]));
        }
        if (self.diagnostics.hasErrors()) return null;

        var lowered: std.ArrayList(mir.build.Lowering) = .empty;
        defer lowered.deinit(self.arena);
        try self.lowerFunctions(bodies.items, &lowered);

        const entry_index = self.entry_function orelse return null;

        const interface_witnesses = try self.arena.alloc(
            mir.InterfaceWitness,
            self.conformances.items.len,
        );
        for (self.conformances.items, interface_witnesses) |implementation, *witness| {
            witness.* = .{
                .interface = self.interface_decls.items[implementation.interface].layout,
                .receiver = implementation.receiver,
                .methods = implementation.methods,
            };
        }

        return .{
            .structs = try self.structs.toOwnedSlice(self.arena),
            .heap_types = try self.heap_types.toOwnedSlice(self.arena),
            .signatures = try self.signatures.toOwnedSlice(self.arena),
            .interface_witnesses = interface_witnesses,
            .enums = try self.enums.toOwnedSlice(self.arena),
            .variants = try self.variants.toOwnedSlice(self.arena),
            .functions = try lowered.toOwnedSlice(self.arena),
            .constants = try self.pool.items.toOwnedSlice(self.arena),
            .container_constants = try self.pool.containers.toOwnedSlice(self.arena),
            .entry_function = entry_index,
        };
    }

    // -- the settled tables, read back --------------------------------
    //
    // These stayed methods because each is a read of one table and
    // nothing more: they are what an `Analyzer` *is*, not a job it
    // does.  What fills the tables, and what their contents mean, are
    // the files beside this one.

    pub fn signatureOf(self: *const Analyzer, of: Type) ?types.Signature {
        if (of != .function) return null;
        return self.signatures.items[of.function];
    }

    pub fn heapOf(self: *const Analyzer, of: Type) ?types.HeapType {
        if (of != .heap) return null;
        return self.heap_types.items[of.heap];
    }

    /// The nominal layout behind a class reference, or null for every
    /// other type. Keeping this question here prevents users of `Type.heap`
    /// from each inventing a slightly different class test.
    pub fn classLayout(self: *const Analyzer, of: Type) ?u32 {
        if (of != .heap) return null;
        return switch (self.heap_types.items[of.heap]) {
            .class => |layout| layout,
            else => null,
        };
    }

    /// The declaration layout behind either nominal aggregate kind.
    /// Structs carry their layout directly; classes carry it through the
    /// interned heap descriptor that gives them reference identity.  Field,
    /// method, construction, and conformance code ask this one question so
    /// they cannot accidentally make `class` struct-shaped again.
    pub fn nominalLayout(self: *const Analyzer, of: Type) ?u32 {
        return switch (of) {
            .strukt => |layout| layout,
            .heap => self.classLayout(of),
            else => null,
        };
    }

    /// The enum a written name resolves to, with its width — the one
    /// place an `EnumRef` is built, so the width beside an index is
    /// always the width that index declares.
    pub fn enumType(self: *const Analyzer, index: u32) Type {
        return .{ .enumeration = .{ .index = index, .backing = self.enums.items[index].backing } };
    }

    /// The interface declaration owning a hidden struct layout, if any.
    pub fn interfaceForLayout(self: *const Analyzer, layout: u32) ?u32 {
        for (self.interface_decls.items, 0..) |decl, index| {
            if (decl.layout == layout) return @intCast(index);
        }
        return null;
    }

    /// The explicit implementation row for a concrete struct/interface pair.
    pub fn conformance(self: *const Analyzer, strukt: u32, interface: u32) ?context.InterfaceConformance {
        for (self.conformances.items) |entry| {
            if (entry.strukt == strukt and entry.interface == interface) return entry;
        }
        return null;
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
                const qualified = try naming.qualify(self, module.prefix, declaration.name);
                if (try naming.firstDeclarationOf(self, qualified)) |where| {
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

    // Function bodies ------------------------------------------------------

    /// Check one function body: the walk resolves, types, diagnoses,
    /// and records the typed tree (hir.zig).  Nothing is emitted —
    /// `hir.lower` consumes the answer once the whole program checked
    /// clean.  Null when the walk could not assemble a body, which
    /// only a diagnosed program produces.
    fn checkFunction(self: *Analyzer, info: FunctionDeclInfo) Error!?hir.nodes.Body {
        self.diagnostics.scope = self.modules[info.module].file;
        defer self.diagnostics.scope = source_mod.root_file;
        var builder: builder_mod.FunctionBuilder = .{
            .analyzer = self,
            .module = info.module,
            .prefix = self.modules[info.module].prefix,
            .name = info.name,
            .results = info.results,
            .return_type = info.return_type,
            .fallible = info.fallible,
            .lifecycle = info.lifecycle,
            .static_member = info.lifecycle == .ordinary and info.enclosing != null and info.receiver == .not,
            .enclosing_locals = info.enclosing_locals,
            .closure_captures = info.closure_captures,
        };
        defer builder.deinitScratch();

        if (info.lifecycle == .initializer) {
            const heap = switch (info.enclosing.?) {
                .class => |index| index,
                else => unreachable,
            };
            builder.initializer = .{ .layout = self.heap_types.items[heap].class };
            try initializers.validate(&builder, info.declaration);
        }

        try closures.prepareFunction(&builder, info.declaration.body);

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
            // A parameter borrows its caller's storage: the caller's
            // binding outlives the call and gives the bytes back itself
            // (docs/STRINGS.md).
            _ = (try builder.declareLocalAs(
                parameter.name,
                parameter_type,
                false,
                .borrows,
                parameter.name_span,
            )) orelse continue;
        }

        try builder.lowerBlock(info.declaration.body);
        // The typed tree's `Body` (hir.zig): the walk's whole
        // answer, and the one thing `hir.lower` consumes.
        try builder.finishBody();
        builder.popScope();

        // A typed function must return on every path.  The span is the
        // written return type rather than the `func` line: in a long
        // function that is the claim being broken, and it is what the
        // reader has to change if they meant something else.
        if (info.lifecycle != .initializer and
            info.results.len != 0 and
            !helpers.returnsOnAllPaths(info.declaration.body))
        {
            const at = info.declaration.returnsSpan() orelse info.declaration.span;
            try self.fail(
                "luce.sema.return",
                at,
                "{s} must return {s} on every path, and some path reaches the end of its body without returning",
                .{ info.declaration.name, try signatures.writtenResults(self, &info) },
            );
        }
        return builder.recorded_body;
    }

    /// Lower every checked body onto its own tape, in function order.
    /// Runs only after the whole program checked clean, so every body
    /// is present and gap-free — `hir.lower` asserts the latter.
    fn lowerFunctions(
        self: *Analyzer,
        bodies: []const ?hir.nodes.Body,
        lowered: *std.ArrayList(mir.build.Lowering),
    ) Error!void {
        // Lower's view of the settled tables, derived once: every
        // folded constant's typed value.
        const folded = try self.temporary.alloc(context.TypedConstant, self.constant_infos.items.len);
        defer self.temporary.free(folded);
        for (self.constant_infos.items, folded) |constant, *slot| {
            slot.* = .{ .value = constant.value, .value_type = constant.value_type };
        }

        for (self.functions.items, bodies) |info, recorded| {
            // A clean check records every body whole; an absent one
            // could only mean the walk was diagnosed, and the caller
            // gates on that before coming here.
            const body = &(recorded orelse unreachable);
            var code: mir.build.Lowering = .{
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
            };
            try hir.lower.lowerFunction(.{
                .temporary = self.temporary,
                .heap_types = self.heap_types.items,
                .signatures = self.signatures.items,
                .functions = self.functions.items,
                .constants = folded,
                .function = info,
            }, body, &code);
            // Everything from here — sealing the open blocks, freezing
            // the block lists, turning the recorded source offsets into
            // lines and columns, naming the file — is stage 6's, and
            // runs when `mir.build` closes the tape.
            try lowered.append(self.arena, code);
        }
    }
};
