//! Luce semantic analysis and IR lowering.
//!
//! Two passes: declaration collection (struct layouts, function
//! signatures, the selected entry) and a checked walk of every
//! function body that emits verified-shape Luce IR as it goes.  The
//! type checker knows Luce types and the Texel's Port schema; nothing
//! about any backend appears here.
//!
//! Rules enforced here, per docs/LANGUAGE.md: static types with no
//! implicit numeric conversion, immutable let and parameters, no
//! shadowing, definite initialization (bindings always carry a value),
//! return on every path, input is read-only and output write-only, and
//! only ports the schema declares exist.

const std = @import("std");
const source_mod = @import("../01_source.zig");
const helpers = @import("helpers.zig");
const builder_mod = @import("builder.zig");
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");
const mir = @import("../06_mir.zig");
const diagnostics_mod = @import("../support/diagnostics.zig");

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const Type = types.Type;
const PortSchema = types.PortSchema;
const StructLayout = types.StructLayout;
const Diagnostics = diagnostics_mod.Diagnostics;
const Register = mir.Register;
const BlockId = mir.BlockId;
const LocalId = mir.LocalId;

pub const Error = error{OutOfMemory};

/// Names the language reserves; nothing user-declared may take them.
pub const reserved_names = [_][]const u8{
    "input",       "output",    "Input",      "Output",      "range",
    "Int",         "Float",     "Bool",       "String",      "Bytes",
    "List",        "Map",       "Array",      "Builder",     "None",
    "abs",         "min",       "max",        "clamp",       "sqrt",
    "floor",       "ceil",      "len",        "slice",       "byte_at",
    "assert",      "trap",      "evaluate",   "str",         "parse_int",
    "parse_float", "chr",       "ord",        "append",      "pop",
    "insert",      "remove",    "has",        "dim",         "free",
    "print",       "file_read", "file_write", "file_exists", "arg",
    "arg_count",   "key_read",  "key_text",
};

pub fn isReserved(name: []const u8) bool {
    for (reserved_names) |reserved| {
        if (std.mem.eql(u8, name, reserved)) {
            return !std.mem.eql(u8, name, "evaluate");
        }
    }
    return false;
}

/// The analyzed program parts, all allocated from the program arena.
pub const Analyzed = struct {
    structs: []StructLayout,
    heap_types: []types.HeapType,
    functions: []mir.Function,
    constants: []const []const u8,
    reads: []u32,
    entry_function: u32,
};

/// One file in a project: the root ("" prefix) or an imported module
/// whose declarations are namespaced by its import name.  The source
/// text feeds debug info (span -> line:column origins).
pub const ModuleTree = struct {
    prefix: []const u8,
    tree: *const ast.Program,
    source: []const u8,
};

/// Check the project against the schema and lower it to IR.  Returns
/// null when errors were reported; the diagnostics tell the story.
pub fn analyze(
    arena: Allocator,
    temporary: Allocator,
    modules: []const ModuleTree,
    schema: PortSchema,
    options: types.CompileOptions,
    diagnostics: *Diagnostics,
) Error!?Analyzed {
    var analyzer: Analyzer = .{
        .arena = arena,
        .temporary = temporary,
        .modules = modules,
        .schema = schema,
        .options = options,
        .diagnostics = diagnostics,
    };
    defer analyzer.deinitScratch();
    return analyzer.run();
}

pub const FunctionInfo = struct {
    declaration: *const ast.FuncDecl,
    name: []const u8,
    module: usize,
    parameter_types: []Type,
    parameter_modes: []ast.ParameterMode,
    return_type: Type,
    is_entry: bool,
};

/// A collected struct declaration with its module, for cycle spans
/// and field resolution.
pub const StructDeclInfo = struct {
    declaration: *const ast.StructDecl,
    module: usize,
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

pub const Scope = struct {
    names: std.StringHashMapUnmanaged(LocalInfo) = .empty,
    /// Owned object-carrying locals in declaration order; scope exit
    /// releases them in reverse.
    owned: std.ArrayList(LocalId) = .empty,
};

pub const FoundLocal = struct {
    info: *LocalInfo,
    /// Index of the scope that declared the name (S30 loop guard).
    depth: usize,
};

pub const LoopFrame = struct {
    continue_block: BlockId,
    exit_block: BlockId,
    /// self.scopes.items.len when the loop body began: break and
    /// continue release every scope at or above this depth.
    scope_depth: usize,
    /// self.temps.items.len when the loop body began.
    temps_depth: usize,
};

pub const Analyzer = struct {
    arena: Allocator,
    temporary: Allocator,
    modules: []const ModuleTree,
    schema: PortSchema,
    options: types.CompileOptions,
    diagnostics: *Diagnostics,

    structs: std.ArrayList(StructLayout) = .empty,
    struct_decls: std.ArrayList(StructDeclInfo) = .empty,
    heap_types: std.ArrayList(types.HeapType) = .empty,
    struct_names: std.StringHashMapUnmanaged(u32) = .empty,
    functions: std.ArrayList(FunctionInfo) = .empty,
    function_names: std.StringHashMapUnmanaged(u32) = .empty,
    constants: std.ArrayList([]const u8) = .empty,
    constant_infos: std.ArrayList(ConstantInfo) = .empty,
    constant_names: std.StringHashMapUnmanaged(u32) = .empty,
    reads: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Lazy per-module debug caches: line-start offsets (temporary,
    /// for span -> line:column) and display names (arena — they end
    /// up in mir.Function.source).
    line_tables: std.ArrayList(?[]u32) = .empty,
    source_names: std.ArrayList(?[]const u8) = .empty,

    pub fn deinitScratch(self: *Analyzer) void {
        self.struct_decls.deinit(self.temporary);
        self.struct_names.deinit(self.temporary);
        self.function_names.deinit(self.temporary);
        self.constant_infos.deinit(self.temporary);
        self.constant_names.deinit(self.temporary);
        self.reads.deinit(self.temporary);
        for (self.line_tables.items) |starts| {
            if (starts) |owned| self.temporary.free(owned);
        }
        self.line_tables.deinit(self.temporary);
        self.source_names.deinit(self.temporary);
    }

    pub fn moduleLineStarts(self: *Analyzer, module: usize) Error![]const u32 {
        if (self.line_tables.items.len == 0) {
            try self.line_tables.appendNTimes(self.temporary, null, self.modules.len);
        }
        if (self.line_tables.items[module]) |starts| return starts;
        const source = self.modules[module].source;
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(self.temporary);
        try starts.append(self.temporary, 0);
        for (source, 0..) |character, offset| {
            if (character == '\n') try starts.append(self.temporary, @intCast(offset + 1));
        }
        const owned = try starts.toOwnedSlice(self.temporary);
        self.line_tables.items[module] = owned;
        return owned;
    }

    pub fn moduleSourceName(self: *Analyzer, module: usize) Error![]const u8 {
        if (self.source_names.items.len == 0) {
            try self.source_names.appendNTimes(self.temporary, null, self.modules.len);
        }
        if (self.source_names.items[module]) |name| return name;
        const prefix = self.modules[module].prefix;
        const name: []const u8 = if (prefix.len != 0)
            try std.fmt.allocPrint(self.arena, "{s}.luc", .{prefix})
        else if (self.options.source_name.len != 0)
            try self.arena.dupe(u8, std.fs.path.basename(self.options.source_name))
        else
            "main.luc";
        self.source_names.items[module] = name;
        return name;
    }

    pub fn fail(self: *Analyzer, code: []const u8, span: Span, comptime format: []const u8, arguments: anytype) Error!void {
        try self.diagnostics.add(code, span, format, arguments);
    }

    pub fn run(self: *Analyzer) Error!?Analyzed {
        try self.collectStructs();
        try self.collectConstants();
        try self.collectFunctions();
        if (self.diagnostics.hasErrors()) return null;

        var lowered: std.ArrayList(mir.Function) = .empty;
        defer lowered.deinit(self.arena);
        for (self.functions.items) |info| {
            try lowered.append(self.arena, try self.lowerFunction(info));
        }
        if (self.diagnostics.hasErrors()) return null;

        const entry_name = if (self.options.entry_mode == .evaluator) "evaluate" else "main";
        const entry_index = self.function_names.get(entry_name) orelse return null;

        var reads: std.ArrayList(u32) = .empty;
        defer reads.deinit(self.arena);
        var read_ports = self.reads.keyIterator();
        while (read_ports.next()) |port| try reads.append(self.arena, port.*);
        std.mem.sort(u32, reads.items, {}, std.sort.asc(u32));

        return .{
            .structs = try self.structs.toOwnedSlice(self.arena),
            .heap_types = try self.heap_types.toOwnedSlice(self.arena),
            .functions = try lowered.toOwnedSlice(self.arena),
            .constants = try self.constants.toOwnedSlice(self.arena),
            .reads = try reads.toOwnedSlice(self.arena),
            .entry_function = entry_index,
        };
    }

    // Declarations ---------------------------------------------------------

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

    pub fn resolveType(self: *Analyzer, module: usize, written: ast.TypeName) Error!?Type {
        const table = [_]struct { name: []const u8, resolved: Type }{
            .{ .name = "Bool", .resolved = .boolean },
            .{ .name = "Int", .resolved = .int },
            .{ .name = "Float", .resolved = .float },
            .{ .name = "String", .resolved = .string },
            .{ .name = "Bytes", .resolved = .bytes },
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
                try self.fail("luce.sema.import", written.span, "unknown module {s}; import {s} to use its types", .{ head, head });
                return null;
            }
            if (self.struct_names.get(written.name)) |index| return .{ .strukt = index };
            try self.fail("luce.sema.type", written.span, "unknown type {s}", .{written.name});
            return null;
        }
        const local = try self.qualify(self.modules[module].prefix, written.name);
        if (self.struct_names.get(local)) |index| return .{ .strukt = index };
        try self.fail("luce.sema.type", written.span, "unknown type {s}", .{written.name});
        return null;
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
    /// Struct cycles are rejected before this is ever asked.
    pub fn carriesObjects(self: *const Analyzer, of: Type) bool {
        return switch (of) {
            .heap => true,
            .strukt => |layout_index| blk: {
                for (self.structs.items[layout_index].fields) |field| {
                    if (self.carriesObjects(field.field_type)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    pub fn collectStructs(self: *Analyzer) Error!void {
        // Imports first: names must be usable and free of collisions.
        for (self.modules, 0..) |module, module_index| {
            self.diagnostics.scope = module.prefix;
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
            self.diagnostics.scope = module.prefix;
            for (module.tree.structs) |*declaration| {
                if (isReserved(declaration.name)) {
                    try self.fail("luce.sema.reserved", declaration.span, "{s} is a reserved name", .{declaration.name});
                    continue;
                }
                const qualified = try self.qualify(module.prefix, declaration.name);
                if (self.struct_names.contains(qualified)) {
                    try self.fail("luce.sema.duplicate", declaration.span, "duplicate struct {s}", .{declaration.name});
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
            self.diagnostics.scope = self.modules[info.module].prefix;
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
                    try self.fail("luce.sema.duplicate", field.span, "duplicate field {s}", .{field.name});
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
        // struct) would have no finite value.
        for (self.structs.items, 0..) |_, index| {
            if (self.structCycles(@intCast(index), @intCast(index), 0)) {
                const info = self.struct_decls.items[index];
                self.diagnostics.scope = self.modules[info.module].prefix;
                try self.fail(
                    "luce.sema.struct",
                    info.declaration.span,
                    "struct {s} contains itself",
                    .{self.structs.items[index].name},
                );
            }
        }
        self.diagnostics.scope = "";
    }

    // File-scope constants --------------------------------------------------

    /// Register every module's top-level `let` constants, then fold
    /// each one so every error reports even when nothing uses it.
    pub fn collectConstants(self: *Analyzer) Error!void {
        for (self.modules, 0..) |module, module_index| {
            self.diagnostics.scope = module.prefix;
            for (module.tree.constants) |*declaration| {
                if (isReserved(declaration.name)) {
                    try self.fail("luce.sema.reserved", declaration.span, "{s} is a reserved name", .{declaration.name});
                    continue;
                }
                const qualified = try self.qualify(module.prefix, declaration.name);
                if (self.constant_names.contains(qualified) or self.struct_names.contains(qualified)) {
                    try self.fail("luce.sema.duplicate", declaration.span, "duplicate name {s}", .{declaration.name});
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
            self.diagnostics.scope = self.modules[module].prefix;
            _ = try self.evaluateConstant(@intCast(index));
        }
        self.diagnostics.scope = "";
    }

    /// Fold one constant, lazily and cycle-checked.  Null after a
    /// reported error.
    pub fn evaluateConstant(self: *Analyzer, index: u32) Error!?TypedConstant {
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

    pub fn constantError(self: *Analyzer, span: Span, comptime format: []const u8, arguments: anytype) Error!?TypedConstant {
        try self.fail("luce.sema.const", span, format, arguments);
        return null;
    }

    /// Fold a constant expression: literals, other constants
    /// (`pi`, `geo.pi`, struct-constant fields), arithmetic and
    /// comparisons, string concatenation, `Int`/`Float` conversions,
    /// and value-struct construction.  Objects and calls are not
    /// constants.
    pub fn foldConstant(self: *Analyzer, module: usize, expression: *const ast.Expression) Error!?TypedConstant {
        switch (expression.*) {
            .int_literal => |literal| {
                const parsed = std.fmt.parseInt(i64, literal.text, 10) catch {
                    return self.constantError(literal.span, "integer literal out of range", .{});
                };
                return .{ .value = .{ .int = parsed }, .value_type = .int };
            },
            .float_literal => |literal| {
                const parsed = std.fmt.parseFloat(f64, literal.text) catch {
                    return self.constantError(literal.span, "malformed float literal", .{});
                };
                return .{ .value = .{ .float = parsed }, .value_type = .float };
            },
            .bool_literal => |literal| {
                return .{ .value = .{ .boolean = literal.value }, .value_type = .boolean };
            },
            .string_literal => |literal| {
                return .{ .value = .{ .string = literal.decoded }, .value_type = .string };
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
                if (std.mem.eql(u8, call.callee, "Int") or std.mem.eql(u8, call.callee, "Float")) {
                    if (call.arguments.len != 1 or call.arguments[0].name != null) {
                        return self.constantError(call.span, "{s}(value) takes one argument", .{call.callee});
                    }
                    const operand = (try self.foldConstant(module, call.arguments[0].value)) orelse return null;
                    return self.foldConvert(call, operand);
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
        }
    }

    pub fn foldConvert(self: *Analyzer, call: ast.Call, operand: TypedConstant) Error!?TypedConstant {
        const to_int = std.mem.eql(u8, call.callee, "Int");
        if (to_int) {
            switch (operand.value) {
                .int => return operand,
                .float => |value| {
                    if (std.math.isNan(value) or
                        value < -9223372036854775808.0 or
                        value >= 9223372036854775808.0)
                    {
                        return self.constantError(call.span, "constant conversion out of range", .{});
                    }
                    return .{ .value = .{ .int = @intFromFloat(@trunc(value)) }, .value_type = .int };
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

    pub fn foldConstruct(
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
            return self.constantError(span, "{s} is a function namespace and has no value fields", .{layout.name});
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
                return self.constantError(argument.span, "field {s} given twice", .{name});
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
        for (seen, 0..) |given, field_index| {
            if (!given) {
                return self.constantError(span, "{s} is missing field {s}", .{ layout.name, layout.fields[field_index].name });
            }
        }
        return .{
            .value = .{ .strukt = .{ .layout = layout_index, .fields = fields } },
            .value_type = result_type,
        };
    }

    pub fn foldBinary(self: *Analyzer, module: usize, binary: ast.Binary) Error!?TypedConstant {
        const left = (try self.foldConstant(module, binary.left)) orelse return null;
        // Short-circuit folds without evaluating the other side's
        // side effects — there are none, so plain evaluation is fine.
        const right = (try self.foldConstant(module, binary.right)) orelse return null;
        if (!left.value_type.eql(right.value_type)) {
            return self.constantError(binary.span, "operands are {s} and {s} (conversions are explicit)", .{
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
            .add, .subtract, .multiply, .divide, .remainder => switch (left.value) {
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
                        .divide => blk: {
                            if (b == 0) return self.constantError(binary.span, "constant division by zero", .{});
                            if (a == std.math.minInt(i64) and b == -1) {
                                return self.constantError(binary.span, "constant arithmetic overflows", .{});
                            }
                            break :blk @divTrunc(a, b);
                        },
                        .remainder => blk: {
                            if (b == 0) return self.constantError(binary.span, "constant division by zero", .{});
                            if (a == std.math.minInt(i64) and b == -1) {
                                return self.constantError(binary.span, "constant arithmetic overflows", .{});
                            }
                            break :blk @rem(a, b);
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
                        .remainder => @rem(a, b),
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
        }
    }

    pub fn structCycles(self: *const Analyzer, origin: u32, current: u32, depth: usize) bool {
        if (depth > self.structs.items.len) return true;
        for (self.structs.items[current].fields) |field| {
            if (field.field_type == .strukt) {
                if (field.field_type.strukt == origin) return true;
                if (self.structCycles(origin, field.field_type.strukt, depth + 1)) return true;
            }
        }
        return false;
    }

    pub fn collectFunctions(self: *Analyzer) Error!void {
        for (self.modules, 0..) |module, module_index| {
            self.diagnostics.scope = module.prefix;
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
        self.diagnostics.scope = "";
        try self.checkEntry();
    }

    pub fn collectFunction(
        self: *Analyzer,
        declaration: *const ast.FuncDecl,
        name: []const u8,
        module: usize,
        top_level: bool,
    ) Error!void {
        const in_root = self.modules[module].prefix.len == 0;
        if (isReserved(declaration.name) and
            !(top_level and std.mem.eql(u8, declaration.name, "evaluate")))
        {
            try self.fail("luce.sema.reserved", declaration.span, "{s} is a reserved name", .{declaration.name});
            return;
        }
        if (self.function_names.contains(name) or
            self.constant_names.contains(name) or
            (top_level and self.struct_names.contains(name)))
        {
            try self.fail("luce.sema.duplicate", declaration.span, "duplicate name {s}", .{declaration.name});
            return;
        }

        const entry_name = if (self.options.entry_mode == .evaluator) "evaluate" else "main";
        const is_entry = top_level and in_root and std.mem.eql(u8, declaration.name, entry_name);
        var parameter_types: std.ArrayList(Type) = .empty;
        defer parameter_types.deinit(self.arena);
        var parameter_modes: std.ArrayList(ast.ParameterMode) = .empty;
        defer parameter_modes.deinit(self.arena);
        if (!is_entry) {
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
            .is_entry = is_entry,
        });
    }

    pub fn checkEntry(self: *Analyzer) Error!void {
        const mode = self.options.entry_mode;
        const name = if (mode == .evaluator) "evaluate" else "main";
        const code = if (mode == .evaluator) "luce.sema.evaluate" else "luce.sema.main";
        const index = self.function_names.get(name) orelse {
            try self.fail(code, .{ .start = 0, .end = 0 }, "missing func {s}{s}", .{
                name,
                if (mode == .evaluator) "(input: Input, output: Output):" else "():",
            });
            return;
        };
        const declaration = self.functions.items[index].declaration;
        var valid = declaration.return_type == null;
        if (mode == .evaluator) {
            valid = valid and declaration.parameters.len == 2;
            if (declaration.parameters.len == 2) {
                valid = valid and
                    std.mem.eql(u8, declaration.parameters[0].name, "input") and
                    std.mem.eql(u8, declaration.parameters[0].type_name.name, "Input") and
                    std.mem.eql(u8, declaration.parameters[1].name, "output") and
                    std.mem.eql(u8, declaration.parameters[1].type_name.name, "Output");
            }
            if (!valid) {
                try self.fail(code, declaration.span, "evaluator entry must be exactly func evaluate(input: Input, output: Output):", .{});
            }
        } else if (declaration.parameters.len != 0 or !valid) {
            try self.fail(code, declaration.span, "script entry must be exactly func main():", .{});
        }
    }

    pub fn typeName(self: *Analyzer, of: Type) Error![]const u8 {
        return types.typeName(self.arena, self.structs.items, self.heap_types.items, of);
    }

    pub fn internConstant(self: *Analyzer, bytes: []const u8) Error!u32 {
        for (self.constants.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, bytes)) return @intCast(index);
        }
        const owned = try self.arena.dupe(u8, bytes);
        try self.constants.append(self.arena, owned);
        return @intCast(self.constants.items.len - 1);
    }

    // Function lowering ----------------------------------------------------

    pub fn lowerFunction(self: *Analyzer, info: FunctionInfo) Error!mir.Function {
        self.diagnostics.scope = self.modules[info.module].prefix;
        defer self.diagnostics.scope = "";
        var builder: builder_mod.FunctionBuilder = .{
            .analyzer = self,
            .module = info.module,
            .prefix = self.modules[info.module].prefix,
            .return_type = info.return_type,
            .has_frames = info.is_entry and self.options.entry_mode == .evaluator,
        };
        defer builder.deinitScratch();
        builder.origin = @intCast(info.declaration.span.start);

        try builder.openBlock();
        try builder.pushScope();

        if (!info.is_entry) {
            for (info.declaration.parameters, 0..) |parameter, index| {
                if (index >= info.parameter_types.len) break;
                const parameter_type = info.parameter_types[index];
                const gives = info.parameter_modes[index] == .give;
                const class: OwnershipClass = if (gives) .owned else .borrow_param;
                const local = (try builder.declareLocal(
                    parameter.name,
                    parameter_type,
                    false,
                    class,
                    parameter.span,
                )) orelse continue;
                // A give parameter is an owned binding like any other
                // (S15): take the object over from the caller on entry.
                if (gives) {
                    const value = try builder.emit(.{ .local_get = local }, parameter_type);
                    _ = try builder.emit(.{ .object_bind = .{ .local = local, .value = value } }, .none);
                }
            }
        }

        try builder.lowerBlock(info.declaration.body);
        try builder.emitScopeEnd();
        builder.popScope();

        // A typed function must return on every path.
        if (info.return_type != .none and !helpers.returnsOnAllPaths(info.declaration.body)) {
            try self.fail(
                "luce.sema.return",
                info.declaration.span,
                "{s} does not return a value on every path",
                .{info.declaration.name},
            );
        }
        try builder.sealOpenBlocks();

        const line_starts = try self.moduleLineStarts(info.module);
        const origins = try self.arena.alloc(mir.Origin, builder.origin_offsets.items.len);
        for (builder.origin_offsets.items, origins) |offset, *slot| {
            slot.* = helpers.placeOf(line_starts, offset);
        }

        return .{
            .name = info.name,
            .parameter_count = @intCast(info.parameter_types.len),
            .return_type = info.return_type,
            .locals = try builder.locals.toOwnedSlice(self.arena),
            .instructions = try builder.instructions.toOwnedSlice(self.arena),
            .result_types = try builder.result_types.toOwnedSlice(self.arena),
            .blocks = try builder.finishBlocks(),
            .origins = origins,
            .source = try self.moduleSourceName(info.module),
        };
    }
};
