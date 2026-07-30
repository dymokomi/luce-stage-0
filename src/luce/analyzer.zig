//! Luce semantic analysis and IR lowering.
//!
//! Two passes: declaration collection (struct layouts, function
//! signatures, the selected entry) and a checked walk of every
//! function body that emits verified-shape Luce IR as it goes.  The
//! type checker knows Luce types and the Texel's Port schema; nothing
//! about any backend appears here.
//!
//! Rules enforced here, per docs/LUCE.md: static types with no
//! implicit numeric conversion, immutable let and parameters, no
//! shadowing, definite initialization (bindings always carry a value),
//! return on every path, input is read-only and output write-only, and
//! only ports the schema declares exist.

const std = @import("std");
const source_mod = @import("source.zig");
const ast = @import("ast.zig");
const types = @import("types.zig");
const ir = @import("ir.zig");
const diagnostics_mod = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;
const Span = source_mod.Span;
const Type = types.Type;
const PortSchema = types.PortSchema;
const StructLayout = types.StructLayout;
const Diagnostics = diagnostics_mod.Diagnostics;
const Register = ir.Register;
const BlockId = ir.BlockId;
const LocalId = ir.LocalId;

pub const Error = error{OutOfMemory};

/// Names the language reserves; nothing user-declared may take them.
const reserved_names = [_][]const u8{
    "input",        "output",        "Input",           "Output",       "range",
    "Int",          "Float",         "Bool",            "String",       "Bytes",
    "List",         "Map",           "Array",           "Builder",      "None",
    "abs",          "min",           "max",             "clamp",        "sqrt",
    "floor",        "ceil",          "len",             "slice",        "byte_at",
    "assert",       "trap",          "evaluate",        "str",          "parse_int",
    "parse_float",  "chr",           "ord",             "append",       "pop",
    "insert",       "remove",        "has",             "dim",          "free",
    "print",        "file_read",     "file_write",      "file_exists",  "arg",
    "arg_count",    "key_read",      "key_text",        "create_texel", "texel_input",
    "texel_output", "texel_content", "texel_evaluator", "texel_set",    "create_image",
};

fn isReserved(name: []const u8) bool {
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
    functions: []ir.Function,
    constants: []const []const u8,
    reads: []u32,
    entry_function: u32,
};

/// One file in a project: the root ("" prefix) or an imported module
/// whose declarations are namespaced by its import name.
pub const ModuleTree = struct {
    prefix: []const u8,
    tree: *const ast.Program,
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

const FunctionInfo = struct {
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
const StructDeclInfo = struct {
    declaration: *const ast.StructDecl,
    module: usize,
};

/// The folded value of a file-scope constant.  Constants are values
/// only — scalars, String, and value structs — computed entirely at
/// compile time and inlined at every use site.
const ConstantValue = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8, // arena-owned
    strukt: struct { layout: u32, fields: []ConstantValue },
};

const TypedConstant = struct {
    value: ConstantValue,
    value_type: Type,
};

const ConstantInfo = struct {
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
const OwnershipClass = enum { owned, alias, borrow_param };

const Poison = enum { given, freed };

const LocalInfo = struct {
    local: LocalId,
    mutable: bool,
    class: OwnershipClass = .alias,
    /// The local's type is an object or an object-carrying struct.
    carries: bool = false,
    /// Set by give/free in lowering (= source) order; any later use in
    /// this scope is a compile error (S10, S29).
    poisoned: ?Poison = null,
};

const Scope = struct {
    names: std.StringHashMapUnmanaged(LocalInfo) = .empty,
    /// Owned object-carrying locals in declaration order; scope exit
    /// releases them in reverse.
    owned: std.ArrayList(LocalId) = .empty,
};

const FoundLocal = struct {
    info: *LocalInfo,
    /// Index of the scope that declared the name (S30 loop guard).
    depth: usize,
};

const LoopFrame = struct {
    continue_block: BlockId,
    exit_block: BlockId,
    /// self.scopes.items.len when the loop body began: break and
    /// continue release every scope at or above this depth.
    scope_depth: usize,
    /// self.temps.items.len when the loop body began.
    temps_depth: usize,
};

const Analyzer = struct {
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

    fn deinitScratch(self: *Analyzer) void {
        self.struct_decls.deinit(self.temporary);
        self.struct_names.deinit(self.temporary);
        self.function_names.deinit(self.temporary);
        self.constant_infos.deinit(self.temporary);
        self.constant_names.deinit(self.temporary);
        self.reads.deinit(self.temporary);
    }

    fn fail(self: *Analyzer, code: []const u8, span: Span, comptime format: []const u8, arguments: anytype) Error!void {
        try self.diagnostics.add(code, span, format, arguments);
    }

    fn run(self: *Analyzer) Error!?Analyzed {
        try self.collectStructs();
        try self.collectConstants();
        try self.collectFunctions();
        if (self.diagnostics.hasErrors()) return null;

        var lowered: std.ArrayList(ir.Function) = .empty;
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
    fn qualify(self: *Analyzer, prefix: []const u8, name: []const u8) Error![]const u8 {
        if (prefix.len == 0) return name;
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ prefix, name });
    }

    /// True when `module` imports `name`.
    fn importsModule(self: *const Analyzer, module: usize, name: []const u8) bool {
        for (self.modules[module].tree.imports) |imported| {
            if (std.mem.eql(u8, imported.name, name)) return true;
        }
        return false;
    }

    fn resolveType(self: *Analyzer, module: usize, written: ast.TypeName) Error!?Type {
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
    fn internHeapType(self: *Analyzer, descriptor: types.HeapType) Error!Type {
        for (self.heap_types.items, 0..) |existing, index| {
            if (existing.eql(descriptor)) return .{ .heap = @intCast(index) };
        }
        try self.heap_types.append(self.arena, descriptor);
        return .{ .heap = @intCast(self.heap_types.items.len - 1) };
    }

    fn heapOf(self: *const Analyzer, of: Type) ?types.HeapType {
        if (of != .heap) return null;
        return self.heap_types.items[of.heap];
    }

    /// True for types the ownership rules apply to: heap objects and
    /// structs transitively containing them (S27's "object-carrying").
    /// Struct cycles are rejected before this is ever asked.
    fn carriesObjects(self: *const Analyzer, of: Type) bool {
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

    fn collectStructs(self: *Analyzer) Error!void {
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
    fn collectConstants(self: *Analyzer) Error!void {
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
                    return self.foldConstruct(module, call, layout_index);
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
                            return self.foldConstruct(module, method, layout_index);
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

    fn foldConvert(self: *Analyzer, call: anytype, operand: TypedConstant) Error!?TypedConstant {
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

    fn foldConstruct(self: *Analyzer, module: usize, call: anytype, layout_index: u32) Error!?TypedConstant {
        const layout = self.structs.items[layout_index];
        const result_type: Type = .{ .strukt = layout_index };
        if (self.carriesObjects(result_type)) {
            return self.constantError(call.span, "{s} carries objects; constants are values only [OWNERSHIP.md S35]", .{layout.name});
        }
        if (layout.fields.len == 0) {
            return self.constantError(call.span, "{s} is a function namespace and has no value fields", .{layout.name});
        }
        const fields = try self.arena.alloc(ConstantValue, layout.fields.len);
        const seen = try self.temporary.alloc(bool, layout.fields.len);
        defer self.temporary.free(seen);
        @memset(seen, false);
        for (call.arguments) |argument| {
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
                return self.constantError(call.span, "{s} is missing field {s}", .{ layout.name, layout.fields[field_index].name });
            }
        }
        return .{
            .value = .{ .strukt = .{ .layout = layout_index, .fields = fields } },
            .value_type = result_type,
        };
    }

    fn foldBinary(self: *Analyzer, module: usize, binary: anytype) Error!?TypedConstant {
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
                    .int => |a| compareOrder(binary.op, a, right.value.int),
                    .float => |a| compareOrder(binary.op, a, right.value.float),
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

    fn structCycles(self: *const Analyzer, origin: u32, current: u32, depth: usize) bool {
        if (depth > self.structs.items.len) return true;
        for (self.structs.items[current].fields) |field| {
            if (field.field_type == .strukt) {
                if (field.field_type.strukt == origin) return true;
                if (self.structCycles(origin, field.field_type.strukt, depth + 1)) return true;
            }
        }
        return false;
    }

    fn collectFunctions(self: *Analyzer) Error!void {
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

    fn collectFunction(
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

    fn checkEntry(self: *Analyzer) Error!void {
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

    fn typeName(self: *Analyzer, of: Type) Error![]const u8 {
        return types.typeName(self.arena, self.structs.items, self.heap_types.items, of);
    }

    fn internConstant(self: *Analyzer, bytes: []const u8) Error!u32 {
        for (self.constants.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, bytes)) return @intCast(index);
        }
        const owned = try self.arena.dupe(u8, bytes);
        try self.constants.append(self.arena, owned);
        return @intCast(self.constants.items.len - 1);
    }

    // Function lowering ----------------------------------------------------

    fn lowerFunction(self: *Analyzer, info: FunctionInfo) Error!ir.Function {
        self.diagnostics.scope = self.modules[info.module].prefix;
        defer self.diagnostics.scope = "";
        var builder: FunctionBuilder = .{
            .analyzer = self,
            .module = info.module,
            .prefix = self.modules[info.module].prefix,
            .return_type = info.return_type,
            .has_frames = info.is_entry and self.options.entry_mode == .evaluator,
        };
        defer builder.deinitScratch();

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
        if (info.return_type != .none and !returnsOnAllPaths(info.declaration.body)) {
            try self.fail(
                "luce.sema.return",
                info.declaration.span,
                "{s} does not return a value on every path",
                .{info.declaration.name},
            );
        }
        try builder.sealOpenBlocks();

        return .{
            .name = info.name,
            .parameter_count = @intCast(info.parameter_types.len),
            .return_type = info.return_type,
            .locals = try builder.locals.toOwnedSlice(self.arena),
            .instructions = try builder.instructions.toOwnedSlice(self.arena),
            .result_types = try builder.result_types.toOwnedSlice(self.arena),
            .blocks = try builder.finishBlocks(),
        };
    }
};

fn compareOrder(op: ast.BinaryOp, a: anytype, b: @TypeOf(a)) bool {
    return switch (op) {
        .equal => a == b,
        .not_equal => a != b,
        .less => a < b,
        .less_equal => a <= b,
        .greater => a > b,
        .greater_equal => a >= b,
        else => unreachable,
    };
}

/// Conservative all-paths-return: a block returns when some statement
/// certainly returns; an if returns only when both arms do.  Loops
/// never guarantee a return.
fn returnsOnAllPaths(block: ast.Block) bool {
    for (block.statements) |statement| {
        switch (statement) {
            .return_statement => return true,
            .conditional => |conditional| {
                if (conditional.else_block) |else_block| {
                    if (returnsOnAllPaths(conditional.then_block) and
                        returnsOnAllPaths(else_block)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// FunctionBuilder
// ---------------------------------------------------------------------------

const Value = struct {
    register: Register,
    value_type: Type,
};

const BlockBuilder = struct {
    items: std.ArrayList(Register) = .empty,
    terminated: bool = false,
};

const FunctionBuilder = struct {
    analyzer: *Analyzer,
    module: usize,
    prefix: []const u8,
    return_type: Type,
    has_frames: bool,
    locals: std.ArrayList(ir.Local) = .empty,
    instructions: std.ArrayList(ir.Instruction) = .empty,
    result_types: std.ArrayList(Type) = .empty,
    blocks: std.ArrayList(BlockBuilder) = .empty,
    current: BlockId = 0,
    scopes: std.ArrayList(Scope) = .empty,
    loops: std.ArrayList(LoopFrame) = .empty,
    /// Statement temporaries (S3): every fresh, unowned object is
    /// parked in a hidden local; the end of the statement releases the
    /// ones nothing adopted.  Adoption is a runtime re-owning, so a
    /// stale release is a safe no-op.
    temps: std.ArrayList(TempSlot) = .empty,

    const TempSlot = struct { local: LocalId, register: Register };

    fn arena(self: *FunctionBuilder) Allocator {
        return self.analyzer.arena;
    }

    fn temporary(self: *FunctionBuilder) Allocator {
        return self.analyzer.temporary;
    }

    fn deinitScratch(self: *FunctionBuilder) void {
        for (self.scopes.items) |*scope| {
            scope.names.deinit(self.temporary());
            scope.owned.deinit(self.temporary());
        }
        self.scopes.deinit(self.temporary());
        self.loops.deinit(self.temporary());
        self.temps.deinit(self.temporary());
    }

    fn fail(self: *FunctionBuilder, code: []const u8, span: Span, comptime format: []const u8, arguments: anytype) Error!void {
        try self.analyzer.fail(code, span, format, arguments);
    }

    // Blocks and emission --------------------------------------------------

    fn openBlock(self: *FunctionBuilder) Error!void {
        try self.blocks.append(self.arena(), .{});
        self.current = @intCast(self.blocks.items.len - 1);
    }

    fn reserveBlock(self: *FunctionBuilder) Error!BlockId {
        try self.blocks.append(self.arena(), .{});
        return @intCast(self.blocks.items.len - 1);
    }

    fn switchTo(self: *FunctionBuilder, block: BlockId) void {
        self.current = block;
    }

    fn emit(self: *FunctionBuilder, instruction: ir.Instruction, result: Type) Error!Register {
        const register: Register = @intCast(self.instructions.items.len);
        try self.instructions.append(self.arena(), instruction);
        try self.result_types.append(self.arena(), result);
        const block = &self.blocks.items[self.current];
        if (!block.terminated) {
            try block.items.append(self.arena(), register);
            if (instruction.isTerminator()) block.terminated = true;
        }
        return register;
    }

    /// Every block a function ends with must terminate; unreachable or
    /// fall-through ends get an explicit terminator.
    fn sealOpenBlocks(self: *FunctionBuilder) Error!void {
        for (self.blocks.items, 0..) |*block, index| {
            if (block.terminated and block.items.items.len > 0) continue;
            self.current = @intCast(index);
            block.terminated = false;
            if (self.return_type == .none) {
                _ = try self.emit(.{ .ret = null }, .none);
            } else {
                _ = try self.emit(.{ .trap = .missing_return }, .none);
            }
        }
    }

    fn finishBlocks(self: *FunctionBuilder) Error![]ir.Block {
        const finished = try self.arena().alloc(ir.Block, self.blocks.items.len);
        for (self.blocks.items, finished) |*builder, *block| {
            block.* = .{ .items = try builder.items.toOwnedSlice(self.arena()) };
        }
        self.blocks.deinit(self.arena());
        return finished;
    }

    // Scopes and locals ----------------------------------------------------

    fn pushScope(self: *FunctionBuilder) Error!void {
        try self.scopes.append(self.temporary(), .{});
    }

    fn popScope(self: *FunctionBuilder) void {
        var scope = self.scopes.pop().?;
        scope.names.deinit(self.temporary());
        scope.owned.deinit(self.temporary());
    }

    fn findLocal(self: *FunctionBuilder, name: []const u8) ?FoundLocal {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            if (self.scopes.items[index].names.getPtr(name)) |found| {
                return .{ .info = found, .depth = index };
            }
        }
        return null;
    }

    // Ownership releases -------------------------------------------------

    /// Release one owned local: free whatever objects in its slot are
    /// still bound to it.  Safe on any path — objects given away or
    /// adopted elsewhere are skipped at run time.
    fn emitRelease(self: *FunctionBuilder, local: LocalId) Error!void {
        const value = try self.emit(.{ .local_get = local }, self.locals.items[local].local_type);
        _ = try self.emit(.{ .object_unbind = .{ .local = local, .value = value } }, .none);
    }

    /// Emit releases for the owned locals of every scope at or above
    /// `from`, innermost first, skipping `moved` (a returned binding —
    /// its object moves to the caller, S16).
    fn emitScopeReleases(self: *FunctionBuilder, from: usize, moved: ?LocalId) Error!void {
        var scope_index = self.scopes.items.len;
        while (scope_index > from) {
            scope_index -= 1;
            const owned = self.scopes.items[scope_index].owned.items;
            var owned_index = owned.len;
            while (owned_index > 0) {
                owned_index -= 1;
                if (moved != null and owned[owned_index] == moved.?) continue;
                try self.emitRelease(owned[owned_index]);
            }
        }
    }

    /// Emit releases for the innermost scope, in reverse declaration
    /// order, without popping it: the normal end of a block.
    fn emitScopeEnd(self: *FunctionBuilder) Error!void {
        try self.emitScopeReleases(self.scopes.items.len - 1, null);
    }

    /// Park a fresh, unowned object in a hidden local so the end of
    /// the statement can release it if nothing adopted it (S3, S19).
    fn registerTemp(self: *FunctionBuilder, value: Value) Error!void {
        const local = try self.hiddenLocal(value.value_type);
        _ = try self.emit(.{ .local_set = .{ .local = local, .value = value.register } }, .none);
        _ = try self.emit(.{ .object_bind = .{ .local = local, .value = value.register } }, .none);
        try self.temps.append(self.temporary(), .{ .local = local, .register = value.register });
    }

    /// Emit releases for the temporaries above `from` without
    /// forgetting them (unwinding paths: return, break, continue).
    fn emitTempReleases(self: *FunctionBuilder, from: usize) Error!void {
        var index = self.temps.items.len;
        while (index > from) {
            index -= 1;
            try self.emitRelease(self.temps.items[index].local);
        }
    }

    /// Release and forget the temporaries above `from`: the end of the
    /// statement (or of a condition) that created them.
    fn flushTemps(self: *FunctionBuilder, from: usize) Error!void {
        try self.emitTempReleases(from);
        self.temps.shrinkRetainingCapacity(from);
    }

    /// Resolve a written declaration name from this module's point of
    /// view: bare names are module-local; a dotted name is either a
    /// module-local struct namespace (Text.width) or an imported one
    /// (geo.helper, geo.Text.width).
    fn resolveDeclared(self: *FunctionBuilder, written: []const u8, span: Span) Error!?[]const u8 {
        if (std.mem.indexOfScalar(u8, written, '.')) |dot| {
            const head = written[0..dot];
            const local_head = try self.analyzer.qualify(self.prefix, head);
            if (self.analyzer.struct_names.contains(local_head)) {
                return try self.analyzer.qualify(self.prefix, written);
            }
            if (self.analyzer.importsModule(self.module, head)) {
                return written;
            }
            try self.fail("luce.sema.import", span, "unknown namespace {s}; import {s} to use it", .{ head, head });
            return null;
        }
        return try self.analyzer.qualify(self.prefix, written);
    }

    fn declareLocal(
        self: *FunctionBuilder,
        name: []const u8,
        local_type: Type,
        mutable: bool,
        class: OwnershipClass,
        span: Span,
    ) Error!?LocalId {
        if (isReserved(name) or std.mem.eql(u8, name, "evaluate")) {
            try self.fail("luce.sema.reserved", span, "{s} is a reserved name", .{name});
            return null;
        }
        if (self.findLocal(name) != null) {
            try self.fail("luce.sema.duplicate", span, "{s} is already declared", .{name});
            return null;
        }
        const qualified = try self.analyzer.qualify(self.prefix, name);
        if (self.analyzer.function_names.contains(qualified) or
            self.analyzer.struct_names.contains(qualified) or
            self.analyzer.constant_names.contains(qualified))
        {
            try self.fail("luce.sema.duplicate", span, "{s} is already a declaration", .{name});
            return null;
        }
        const carries = self.analyzer.carriesObjects(local_type);
        const local: LocalId = @intCast(self.locals.items.len);
        try self.locals.append(self.arena(), .{
            .name = try self.arena().dupe(u8, name),
            .local_type = local_type,
        });
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.names.put(self.temporary(), name, .{
            .local = local,
            .mutable = mutable,
            .class = if (carries) class else .alias,
            .carries = carries,
        });
        if (carries and class == .owned) {
            try scope.owned.append(self.temporary(), local);
        }
        return local;
    }

    fn hiddenLocal(self: *FunctionBuilder, local_type: Type) Error!LocalId {
        const local: LocalId = @intCast(self.locals.items.len);
        try self.locals.append(self.arena(), .{
            .name = try self.arena().dupe(u8, "(temporary)"),
            .local_type = local_type,
        });
        return local;
    }

    /// True when lowering this expression may end in a different basic
    /// block than it started: short-circuit `and`/`or` anywhere inside
    /// it branches and merges.
    fn splitsBlocks(expression: *const ast.Expression) bool {
        return switch (expression.*) {
            .binary => |binary| binary.op == .logic_and or binary.op == .logic_or or
                splitsBlocks(binary.left) or splitsBlocks(binary.right),
            .unary => |unary| splitsBlocks(unary.operand),
            .field => |field| splitsBlocks(field.target),
            .call => |call| for (call.arguments) |argument| {
                if (splitsBlocks(argument.value)) break true;
            } else false,
            .new_object => |new| for (new.dims) |dimension| {
                if (splitsBlocks(dimension)) break true;
            } else false,
            .list_literal => |literal| for (literal.elements) |element| {
                if (splitsBlocks(element)) break true;
            } else false,
            .index => |index| splitsBlocks(index.target) or for (index.indices) |item| {
                if (splitsBlocks(item)) break true;
            } else false,
            .slice_range => |slice| splitsBlocks(slice.target) or
                (slice.start != null and splitsBlocks(slice.start.?)) or
                (slice.end != null and splitsBlocks(slice.end.?)),
            .method => |method| splitsBlocks(method.target) or for (method.arguments) |argument| {
                if (splitsBlocks(argument.value)) break true;
            } else false,
            .give => |give| splitsBlocks(give.operand),
            .copy => |copied| splitsBlocks(copied.operand),
            else => false,
        };
    }

    // Ownership classification ---------------------------------------------

    /// True when evaluating this expression yields an object the
    /// receiver may own: something fresh (new, a literal, a slice, a
    /// call result, pop/split/keys), a give, or a copy.  Names and
    /// element/field reads are borrows (S8, S22).  Only consulted for
    /// object-carrying types, so value-typed calls answering true is
    /// harmless.
    fn yieldsOwnership(self: *FunctionBuilder, expression: *const ast.Expression) Error!bool {
        return switch (expression.*) {
            .new_object, .list_literal, .slice_range, .call, .give, .copy => true,
            .method => |method| blk: {
                if (try self.methodIsNamespaced(method)) break :blk true;
                break :blk std.mem.eql(u8, method.name, "pop") or
                    std.mem.eql(u8, method.name, "split") or
                    std.mem.eql(u8, method.name, "keys");
            },
            else => false,
        };
    }

    /// Side-effect-free twin of methodNamespace: does target.name(...)
    /// resolve to a declaration (whose result the caller owns, S16)
    /// rather than a builtin method on a value?
    fn methodIsNamespaced(self: *FunctionBuilder, method: anytype) Error!bool {
        var parts: [3][]const u8 = undefined;
        var count: usize = 0;
        var walk: *const ast.Expression = method.target;
        while (true) {
            switch (walk.*) {
                .name => |name| {
                    if (count == 3) return false;
                    parts[count] = name.text;
                    count += 1;
                    break;
                },
                .field => |field| {
                    if (count == 3) return false;
                    parts[count] = field.name;
                    count += 1;
                    walk = field.target;
                },
                else => return false,
            }
        }
        const head = parts[count - 1];
        if (self.findLocal(head) != null) return false;
        const head_qualified = try self.analyzer.qualify(self.prefix, head);
        if (self.analyzer.struct_names.contains(head_qualified)) return true;
        return self.analyzer.importsModule(self.module, head);
    }

    /// Report a use of a poisoned name (S10, S29); true when poisoned.
    fn checkPoisoned(self: *FunctionBuilder, info: *const LocalInfo, name: []const u8, span: Span) Error!bool {
        const why = info.poisoned orelse return false;
        try self.fail(
            "luce.sema.own",
            span,
            "{s} was {s} and cannot be touched again in this scope [OWNERSHIP.md {s}]",
            .{
                name,
                if (why == .given) @as([]const u8, "given away") else "freed",
                if (why == .given) @as([]const u8, "S10, S29") else "S6",
            },
        );
        return true;
    }

    /// Lower a left-to-right operand sequence whose registers must all
    /// be usable together afterwards.  Registers are block-local, so
    /// every operand followed by a block-splitting one is carried
    /// across the split in a hidden local and re-loaded at the end.
    /// The returned values live in the arena.
    fn lowerOperands(self: *FunctionBuilder, expressions: []const *ast.Expression) Error!?[]Value {
        const values = try self.arena().alloc(Value, expressions.len);
        const spills = try self.temporary().alloc(?LocalId, expressions.len);
        defer self.temporary().free(spills);

        var later_splits = try self.temporary().alloc(bool, expressions.len);
        defer self.temporary().free(later_splits);
        var any_split = false;
        var backwards = expressions.len;
        while (backwards > 0) {
            backwards -= 1;
            later_splits[backwards] = any_split;
            if (splitsBlocks(expressions[backwards])) any_split = true;
        }

        for (expressions, 0..) |expression, index| {
            const value = (try self.lowerExpression(expression, false)) orelse return null;
            values[index] = value;
            spills[index] = null;
            if (later_splits[index] and value.value_type != .none) {
                const local = try self.hiddenLocal(value.value_type);
                _ = try self.emit(.{ .local_set = .{ .local = local, .value = value.register } }, .none);
                spills[index] = local;
            }
        }
        for (spills, 0..) |spill, index| {
            if (spill) |local| {
                values[index].register = try self.emit(.{ .local_get = local }, values[index].value_type);
            }
        }
        return values;
    }

    // Statements -----------------------------------------------------------

    fn lowerBlock(self: *FunctionBuilder, block: ast.Block) Error!void {
        try self.pushScope();
        for (block.statements) |statement| {
            // Fresh objects nothing adopted die with their statement
            // (S3); the release is a no-op for everything adopted.
            const temps_floor = self.temps.items.len;
            try self.lowerStatement(statement);
            try self.flushTemps(temps_floor);
        }
        try self.emitScopeEnd();
        self.popScope();
    }

    fn lowerStatement(self: *FunctionBuilder, statement: ast.Statement) Error!void {
        switch (statement) {
            .let => |binding| try self.lowerBinding(binding.name, binding.annotation, binding.value, false, binding.span),
            .variable => |binding| {
                if (binding.value) |value| {
                    try self.lowerBinding(binding.name, binding.annotation, value, true, binding.span);
                } else {
                    try self.lowerLateDeclaration(binding.name, binding.annotation.?, binding.span);
                }
            },
            .assign => |assign| try self.lowerAssign(assign),
            .conditional => |conditional| try self.lowerConditional(conditional),
            .while_loop => |loop| try self.lowerWhile(loop),
            .for_range => |loop| try self.lowerForRange(loop),
            .for_each => |loop| try self.lowerForEach(loop),
            .return_statement => |returned| try self.lowerReturn(returned),
            .break_statement => |broke| {
                if (self.loops.items.len == 0) {
                    try self.fail("luce.sema.loop", broke.span, "break outside a loop", .{});
                    return;
                }
                const frame = self.loops.items[self.loops.items.len - 1];
                // Early exits unwind what the scopes they leave still
                // own (S4).
                try self.emitTempReleases(frame.temps_depth);
                try self.emitScopeReleases(frame.scope_depth, null);
                _ = try self.emit(.{ .jump = frame.exit_block }, .none);
            },
            .continue_statement => |continued| {
                if (self.loops.items.len == 0) {
                    try self.fail("luce.sema.loop", continued.span, "continue outside a loop", .{});
                    return;
                }
                const frame = self.loops.items[self.loops.items.len - 1];
                try self.emitTempReleases(frame.temps_depth);
                try self.emitScopeReleases(frame.scope_depth, null);
                _ = try self.emit(.{ .jump = frame.continue_block }, .none);
            },
            .expression => |expression| {
                _ = try self.lowerExpression(expression.value, true);
            },
        }
    }

    fn lowerBinding(
        self: *FunctionBuilder,
        name: []const u8,
        annotation: ?ast.TypeName,
        value_expression: *ast.Expression,
        mutable: bool,
        span: Span,
    ) Error!void {
        // An empty [] has no element type of its own; the annotation
        // supplies it: var xs: List(Int) = []
        if (value_expression.* == .list_literal and value_expression.list_literal.elements.len == 0) {
            const written = annotation orelse {
                try self.fail(
                    "luce.sema.type",
                    span,
                    "an empty [] needs an annotation: var {s}: List(T) = []",
                    .{name},
                );
                return;
            };
            const expected = (try self.analyzer.resolveType(self.module, written)) orelse return;
            const descriptor = self.analyzer.heapOf(expected);
            if (descriptor == null or descriptor.? != .list) {
                try self.fail("luce.sema.type", span, "[] builds a List, but {s} is annotated {s}", .{
                    name,
                    try self.analyzer.typeName(expected),
                });
                return;
            }
            const list = try self.emit(.{ .heap_new = .{ .heap = expected.heap, .dims = &.{} } }, expected);
            const local = (try self.declareLocal(name, expected, mutable, .owned, span)) orelse return;
            _ = try self.emit(.{ .local_set = .{ .local = local, .value = list } }, .none);
            _ = try self.emit(.{ .object_bind = .{ .local = local, .value = list } }, .none);
            return;
        }

        const value = (try self.lowerExpression(value_expression, false)) orelse return;
        if (annotation) |written| {
            const expected = (try self.analyzer.resolveType(self.module, written)) orelse return;
            if (!value.value_type.eql(expected)) {
                try self.fail(
                    "luce.sema.type",
                    span,
                    "{s} declared {s} but initialized with {s} (conversions are explicit: {s}(...))",
                    .{ name, try self.analyzer.typeName(expected), try self.analyzer.typeName(value.value_type), try self.analyzer.typeName(expected) },
                );
                return;
            }
        }
        // A binding that received something fresh (or a give, or a
        // copy) owns the object; receiving another name is an alias
        // (S1, S8).
        const owns = self.analyzer.carriesObjects(value.value_type) and
            try self.yieldsOwnership(value_expression);
        const local = (try self.declareLocal(
            name,
            value.value_type,
            mutable,
            if (owns) .owned else .alias,
            span,
        )) orelse return;
        _ = try self.emit(.{ .local_set = .{ .local = local, .value = value.register } }, .none);
        if (owns) {
            _ = try self.emit(.{ .object_bind = .{ .local = local, .value = value.register } }, .none);
        }
    }

    /// var name: Type — a late declaration (OWNERSHIP.md S40): the
    /// slot starts at the type's zero value; the zero of an object
    /// type is the null object, which traps on use until assigned.
    fn lowerLateDeclaration(
        self: *FunctionBuilder,
        name: []const u8,
        written: ast.TypeName,
        span: Span,
    ) Error!void {
        const declared = (try self.analyzer.resolveType(self.module, written)) orelse return;
        const zero = try self.emitZero(declared);
        // The declaration establishes the binding and its scope; the
        // scope owns whatever a later assignment fills in (S36, S40).
        const local = (try self.declareLocal(name, declared, true, .owned, span)) orelse return;
        _ = try self.emit(.{ .local_set = .{ .local = local, .value = zero } }, .none);
    }

    /// The zero value of a type, as instructions: numbers zero, Bool
    /// false, text empty, structs zeroed field by field, objects null.
    fn emitZero(self: *FunctionBuilder, of: Type) Error!Register {
        return switch (of) {
            .none => unreachable, // no annotation resolves to None
            .boolean => try self.emit(.{ .const_boolean = false }, .boolean),
            .int => try self.emit(.{ .const_int = 0 }, .int),
            .float => try self.emit(.{ .const_float = 0.0 }, .float),
            .string, .bytes => blk: {
                const constant = try self.analyzer.internConstant("");
                break :blk try self.emit(
                    .{ .const_data = .{ .constant = constant, .data_type = of } },
                    of,
                );
            },
            .heap => try self.emit(
                .{ .intrinsic = .{ .kind = .null_object, .arguments = &.{} } },
                of,
            ),
            .strukt => |layout_index| blk: {
                const layout = self.analyzer.structs.items[layout_index];
                const fields = try self.arena().alloc(Register, layout.fields.len);
                for (layout.fields, fields) |field, *slot| {
                    slot.* = try self.emitZero(field.field_type);
                }
                break :blk try self.emit(
                    .{ .struct_make = .{ .layout = layout_index, .fields = fields } },
                    of,
                );
            },
        };
    }

    fn lowerAssign(self: *FunctionBuilder, assign: anytype) Error!void {
        switch (assign.target) {
            .name => |name| try self.lowerAssignName(name.text, name.span, assign),
            .field => |field| try self.lowerAssignField(field, assign),
            .index => |index| try self.lowerAssignIndex(index, assign),
        }
    }

    fn lowerAssignName(self: *FunctionBuilder, base: []const u8, span: Span, assign: anytype) Error!void {
        if (std.mem.eql(u8, base, "output")) {
            try self.fail("luce.sema.output", span, "assign to output.NAME", .{});
            return;
        }
        if (std.mem.eql(u8, base, "input")) {
            try self.fail("luce.sema.input", span, "input ports are read-only", .{});
            return;
        }
        const found = self.findLocal(base) orelse {
            const qualified = try self.analyzer.qualify(self.prefix, base);
            if (self.analyzer.constant_names.contains(qualified)) {
                try self.fail("luce.sema.let", span, "{s} is a file-scope constant and cannot be assigned", .{base});
            } else {
                try self.fail("luce.sema.name", span, "unknown name {s}", .{base});
            }
            return;
        };
        const info = found.info;
        if (!info.mutable) {
            try self.fail("luce.sema.let", span, "{s} is let-bound; use var for reassignment", .{base});
            return;
        }
        if (try self.checkPoisoned(info, base, span)) return;
        const local = info.local;
        const class = info.class;
        const local_type = self.locals.items[local].local_type;
        if (info.carries) {
            const yields = try self.yieldsOwnership(assign.value);
            if (class == .owned and !yields) {
                try self.fail(
                    "luce.sema.own",
                    assign.span,
                    "{s} owns its object; assign something fresh, give NAME, or copy NAME [OWNERSHIP.md S5, S21]",
                    .{base},
                );
                return;
            }
            if (class != .owned and yields) {
                try self.fail(
                    "luce.sema.own",
                    assign.span,
                    "{s} aliases another binding's object and cannot own a fresh one; declare a new name [OWNERSHIP.md S8]",
                    .{base},
                );
                return;
            }
        }
        const value = (try self.lowerExpression(assign.value, false)) orelse return;
        if (!value.value_type.eql(local_type)) {
            try self.fail("luce.sema.type", assign.span, "{s} is {s} but the value is {s}", .{
                base,
                try self.analyzer.typeName(local_type),
                try self.analyzer.typeName(value.value_type),
            });
            return;
        }
        // Reassigning an owning var frees the old object immediately
        // (S5); the very first assignment finds only the null object.
        if (info.carries and class == .owned) {
            try self.emitRelease(local);
        }
        _ = try self.emit(.{ .local_set = .{ .local = local, .value = value.register } }, .none);
        if (info.carries and class == .owned) {
            _ = try self.emit(.{ .object_bind = .{ .local = local, .value = value.register } }, .none);
        }
    }

    fn lowerAssignField(self: *FunctionBuilder, target: anytype, assign: anytype) Error!void {
        if (std.mem.eql(u8, target.base, "output")) {
            if (!self.has_frames) {
                try self.fail("luce.sema.name", target.span, "output exists only in the evaluator entry", .{});
                return;
            }
            const port = self.analyzer.schema.findOutput(target.field) orelse {
                try self.fail("luce.sema.port", target.span, "no output port named {s}", .{target.field});
                return;
            };
            const expected = Type.fromPort(self.analyzer.schema.outputs[port].declared);
            const value = (try self.lowerExpression(assign.value, false)) orelse return;
            if (!value.value_type.eql(expected)) {
                try self.fail("luce.sema.type", assign.span, "output.{s} is {s} but the value is {s}", .{
                    target.field,
                    try self.analyzer.typeName(expected),
                    try self.analyzer.typeName(value.value_type),
                });
                return;
            }
            _ = try self.emit(.{ .output_store = .{ .port = port, .value = value.register } }, .none);
            return;
        }
        if (std.mem.eql(u8, target.base, "input")) {
            if (self.has_frames) {
                try self.fail("luce.sema.input", target.span, "input ports are read-only", .{});
            } else {
                try self.fail("luce.sema.name", target.span, "input exists only in the evaluator entry", .{});
            }
            return;
        }

        const found = self.findLocal(target.base) orelse {
            try self.fail("luce.sema.name", target.span, "unknown name {s}", .{target.base});
            return;
        };
        const info = found.info;
        if (!info.mutable) {
            try self.fail("luce.sema.let", target.span, "{s} is let-bound; use var for reassignment", .{target.base});
            return;
        }
        if (try self.checkPoisoned(info, target.base, target.span)) return;
        const local = info.local;
        const local_type = self.locals.items[local].local_type;
        if (local_type != .strukt) {
            try self.fail("luce.sema.field", target.span, "{s} is {s}, not a struct", .{
                target.base,
                try self.analyzer.typeName(local_type),
            });
            return;
        }
        const layout_index = local_type.strukt;
        const layout = self.analyzer.structs.items[layout_index];
        const field_index = layout.findField(target.field) orelse {
            try self.fail("luce.sema.field", target.span, "{s} has no field {s}", .{ layout.name, target.field });
            return;
        };
        const expected = layout.fields[field_index].field_type;
        // An object field follows the verb rule and its owner drops
        // the old value (S25); only the owning binding can restock it.
        const field_carries = self.analyzer.carriesObjects(expected);
        if (field_carries) {
            if (info.class != .owned) {
                try self.fail(
                    "luce.sema.own",
                    target.span,
                    "{s} does not own its objects; assign the field through the owning name [OWNERSHIP.md S25, S26]",
                    .{target.base},
                );
                return;
            }
            if (!(try self.yieldsOwnership(assign.value))) {
                try self.fail(
                    "luce.sema.own",
                    assign.span,
                    "this field keeps its object; assign something fresh, give NAME, or copy NAME [OWNERSHIP.md S21, S25]",
                    .{},
                );
                return;
            }
        }
        const value = (try self.lowerExpression(assign.value, false)) orelse return;
        if (!value.value_type.eql(expected)) {
            try self.fail("luce.sema.type", assign.span, "{s}.{s} is {s} but the value is {s}", .{
                target.base,
                target.field,
                try self.analyzer.typeName(expected),
                try self.analyzer.typeName(value.value_type),
            });
            return;
        }
        const current = try self.emit(.{ .local_get = local }, local_type);
        if (field_carries) {
            const old_field = try self.emit(.{ .struct_get = .{
                .target = current,
                .layout = layout_index,
                .field = field_index,
            } }, expected);
            _ = try self.emit(.{ .object_unbind = .{ .local = local, .value = old_field } }, .none);
        }
        const updated = try self.emit(.{ .struct_set = .{
            .target = current,
            .layout = layout_index,
            .field = field_index,
            .value = value.register,
        } }, local_type);
        _ = try self.emit(.{ .local_set = .{ .local = local, .value = updated } }, .none);
        if (field_carries) {
            _ = try self.emit(.{ .object_bind = .{ .local = local, .value = value.register } }, .none);
        }
    }

    /// place[i] = v, grid[r, c] = v, m[key] = v.  The base may be any
    /// expression: objects mutate through the reference, so no local
    /// write-back is needed.
    fn lowerAssignIndex(self: *FunctionBuilder, target: anytype, assign: anytype) Error!void {
        const expressions = try self.arena().alloc(*ast.Expression, target.indices.len + 2);
        expressions[0] = target.base;
        @memcpy(expressions[1 .. 1 + target.indices.len], target.indices);
        expressions[expressions.len - 1] = assign.value;
        const values = (try self.lowerOperands(expressions)) orelse return;

        const object = values[0];
        const indices = values[1 .. values.len - 1];
        const value = values[values.len - 1];
        const element_type = (try self.checkIndex(object, indices, target.span)) orelse return;
        // Containers own their object elements: storing one takes a
        // fresh value, a give, or a copy (S20, S21).
        if (self.analyzer.carriesObjects(element_type) and
            !(try self.yieldsOwnership(assign.value)))
        {
            try self.fail(
                "luce.sema.own",
                assign.span,
                "a container keeps its object elements; store something fresh, give NAME, or copy NAME [OWNERSHIP.md S21]",
                .{},
            );
            return;
        }
        if (!value.value_type.eql(element_type)) {
            try self.fail("luce.sema.type", assign.span, "this place holds {s} but the value is {s}", .{
                try self.analyzer.typeName(element_type),
                try self.analyzer.typeName(value.value_type),
            });
            return;
        }
        const arguments = try self.arena().alloc(Register, values.len);
        for (values, arguments) |lowered, *slot| slot.* = lowered.register;
        _ = try self.emit(.{ .intrinsic = .{ .kind = .index_set, .arguments = arguments } }, .none);
    }

    /// Type-check lowered index values against a heap object: lists
    /// take one Int, arrays take rank Ints, maps take one key.
    /// Returns the element/value type.
    fn checkIndex(
        self: *FunctionBuilder,
        object: Value,
        indices: []const Value,
        span: Span,
    ) Error!?Type {
        const descriptor = self.analyzer.heapOf(object.value_type) orelse {
            if (object.value_type == .string) {
                try self.fail("luce.sema.index", span, "strings are sliced (s[a:b] or slice), not indexed; byte_at reads bytes", .{});
            } else {
                try self.fail("luce.sema.index", span, "{s} cannot be indexed", .{
                    try self.analyzer.typeName(object.value_type),
                });
            }
            return null;
        };
        if (indices.len > 4) {
            try self.fail("luce.sema.index", span, "at most 4 index dimensions", .{});
            return null;
        }

        switch (descriptor) {
            .list => |element| {
                if (indices.len != 1 or indices[0].value_type != .int) {
                    try self.fail("luce.sema.index", span, "lists index with one Int", .{});
                    return null;
                }
                return element;
            },
            .array => |shape| {
                if (indices.len != shape.rank) {
                    try self.fail("luce.sema.index", span, "this array has {d} dimensions, got {d} indices", .{
                        shape.rank,
                        indices.len,
                    });
                    return null;
                }
                for (indices) |index_value| {
                    if (index_value.value_type != .int) {
                        try self.fail("luce.sema.index", span, "array indices are Int", .{});
                        return null;
                    }
                }
                return shape.element;
            },
            .map => |pair| {
                if (indices.len != 1 or !indices[0].value_type.eql(pair.key)) {
                    try self.fail("luce.sema.index", span, "this map is keyed by {s}", .{
                        try self.analyzer.typeName(pair.key),
                    });
                    return null;
                }
                return pair.value;
            },
            .builder => {
                try self.fail("luce.sema.index", span, "Builder has no index; str(b) reads it", .{});
                return null;
            },
        }
    }

    fn lowerCondition(self: *FunctionBuilder, expression: *ast.Expression) Error!?Value {
        const condition = (try self.lowerExpression(expression, false)) orelse return null;
        if (condition.value_type != .boolean) {
            try self.fail("luce.sema.type", expression.span(), "condition must be Bool, not {s}", .{
                try self.analyzer.typeName(condition.value_type),
            });
            return null;
        }
        return condition;
    }

    fn lowerConditional(self: *FunctionBuilder, conditional: anytype) Error!void {
        const temps_floor = self.temps.items.len;
        const condition = (try self.lowerCondition(conditional.condition)) orelse return;
        // Condition temporaries die before the branch: the condition
        // value is a Bool, so nothing still needs them.
        try self.flushTemps(temps_floor);
        const then_block = try self.reserveBlock();
        const merge_block = try self.reserveBlock();
        var else_target = merge_block;
        if (conditional.else_block != null) {
            else_target = try self.reserveBlock();
        }
        _ = try self.emit(.{ .branch = .{
            .condition = condition.register,
            .then_block = then_block,
            .else_block = else_target,
        } }, .none);

        self.switchTo(then_block);
        try self.lowerBlock(conditional.then_block);
        _ = try self.emit(.{ .jump = merge_block }, .none);

        if (conditional.else_block) |else_block| {
            self.switchTo(else_target);
            try self.lowerBlock(else_block);
            _ = try self.emit(.{ .jump = merge_block }, .none);
        }
        self.switchTo(merge_block);
    }

    fn lowerWhile(self: *FunctionBuilder, loop: anytype) Error!void {
        const header = try self.reserveBlock();
        const body = try self.reserveBlock();
        const exit = try self.reserveBlock();
        _ = try self.emit(.{ .jump = header }, .none);

        self.switchTo(header);
        const temps_floor = self.temps.items.len;
        const condition = (try self.lowerCondition(loop.condition)) orelse {
            _ = try self.emit(.{ .jump = exit }, .none);
            self.switchTo(exit);
            return;
        };
        // The header re-runs every iteration: its temporaries must die
        // in it, not after the loop.
        try self.flushTemps(temps_floor);
        _ = try self.emit(.{ .branch = .{
            .condition = condition.register,
            .then_block = body,
            .else_block = exit,
        } }, .none);

        self.switchTo(body);
        try self.loops.append(self.temporary(), .{
            .continue_block = header,
            .exit_block = exit,
            .scope_depth = self.scopes.items.len,
            .temps_depth = self.temps.items.len,
        });
        try self.lowerBlock(loop.body);
        _ = self.loops.pop();
        _ = try self.emit(.{ .jump = header }, .none);

        self.switchTo(exit);
    }

    fn lowerForRange(self: *FunctionBuilder, loop: anytype) Error!void {
        const temps_floor = self.temps.items.len;
        const bounds = (try self.lowerOperands(&.{ loop.start, loop.end })) orelse return;
        const start = bounds[0];
        const end = bounds[1];
        if (start.value_type != .int or end.value_type != .int) {
            try self.fail("luce.sema.type", loop.span, "range bounds must be Int", .{});
            return;
        }
        // Bound temporaries die before the loop starts.
        try self.flushTemps(temps_floor);

        try self.pushScope();
        defer self.popScope();
        const index_local = (try self.declareLocal(loop.name, .int, false, .alias, loop.span)) orelse return;
        const limit_local = try self.hiddenLocal(.int);
        _ = try self.emit(.{ .local_set = .{ .local = index_local, .value = start.register } }, .none);
        _ = try self.emit(.{ .local_set = .{ .local = limit_local, .value = end.register } }, .none);

        const header = try self.reserveBlock();
        const body = try self.reserveBlock();
        const step = try self.reserveBlock();
        const exit = try self.reserveBlock();
        _ = try self.emit(.{ .jump = header }, .none);

        self.switchTo(header);
        const index_value = try self.emit(.{ .local_get = index_local }, .int);
        const limit_value = try self.emit(.{ .local_get = limit_local }, .int);
        const keep_going = try self.emit(.{ .binary = .{
            .op = .less,
            .operand_type = .int,
            .left = index_value,
            .right = limit_value,
        } }, .boolean);
        _ = try self.emit(.{ .branch = .{
            .condition = keep_going,
            .then_block = body,
            .else_block = exit,
        } }, .none);

        self.switchTo(body);
        try self.loops.append(self.temporary(), .{
            .continue_block = step,
            .exit_block = exit,
            .scope_depth = self.scopes.items.len,
            .temps_depth = self.temps.items.len,
        });
        try self.lowerBlock(loop.body);
        _ = self.loops.pop();
        _ = try self.emit(.{ .jump = step }, .none);

        self.switchTo(step);
        const stepped_index = try self.emit(.{ .local_get = index_local }, .int);
        const one = try self.emit(.{ .const_int = 1 }, .int);
        const incremented = try self.emit(.{ .binary = .{
            .op = .add,
            .operand_type = .int,
            .left = stepped_index,
            .right = one,
        } }, .int);
        _ = try self.emit(.{ .local_set = .{ .local = index_local, .value = incremented } }, .none);
        _ = try self.emit(.{ .jump = header }, .none);

        self.switchTo(exit);
    }

    /// for x in xs: — a hidden object local and a hidden Int index
    /// drive the loop; the element (or map key) binds immutably each
    /// iteration.  Length is re-read every step, so mutation during
    /// iteration stays bounds-safe.
    fn lowerForEach(self: *FunctionBuilder, loop: anytype) Error!void {
        const iterable = (try self.lowerExpression(loop.iterable, false)) orelse return;
        const descriptor = self.analyzer.heapOf(iterable.value_type) orelse {
            try self.fail("luce.sema.loop", loop.span, "for iterates a List, a rank-1 Array, or a Map's keys, not {s}", .{
                try self.analyzer.typeName(iterable.value_type),
            });
            return;
        };
        var element_kind: ir.Intrinsic = .index_get;
        const element_type: Type = switch (descriptor) {
            .list => |element| element,
            .array => |shape| blk: {
                if (shape.rank != 1) {
                    try self.fail("luce.sema.loop", loop.span, "for iterates rank-1 arrays; index higher ranks explicitly", .{});
                    return;
                }
                break :blk shape.element;
            },
            .map => |pair| blk: {
                element_kind = .key_at;
                break :blk pair.key;
            },
            .builder => {
                try self.fail("luce.sema.loop", loop.span, "Builder is not iterable", .{});
                return;
            },
        };

        try self.pushScope();
        defer self.popScope();
        const object_local = try self.hiddenLocal(iterable.value_type);
        const index_local = try self.hiddenLocal(.int);
        // The element binds each iteration as a borrow (S22).
        const name_local = (try self.declareLocal(loop.name, element_type, false, .alias, loop.span)) orelse return;
        _ = try self.emit(.{ .local_set = .{ .local = object_local, .value = iterable.register } }, .none);
        const zero = try self.emit(.{ .const_int = 0 }, .int);
        _ = try self.emit(.{ .local_set = .{ .local = index_local, .value = zero } }, .none);

        const header = try self.reserveBlock();
        const body = try self.reserveBlock();
        const step = try self.reserveBlock();
        const exit = try self.reserveBlock();
        _ = try self.emit(.{ .jump = header }, .none);

        self.switchTo(header);
        const object_value = try self.emit(.{ .local_get = object_local }, iterable.value_type);
        const length_arguments = try self.arena().alloc(Register, 1);
        length_arguments[0] = object_value;
        const length = try self.emit(.{ .intrinsic = .{ .kind = .len, .arguments = length_arguments } }, .int);
        const index_value = try self.emit(.{ .local_get = index_local }, .int);
        const keep_going = try self.emit(.{ .binary = .{
            .op = .less,
            .operand_type = .int,
            .left = index_value,
            .right = length,
        } }, .boolean);
        _ = try self.emit(.{ .branch = .{
            .condition = keep_going,
            .then_block = body,
            .else_block = exit,
        } }, .none);

        self.switchTo(body);
        const body_object = try self.emit(.{ .local_get = object_local }, iterable.value_type);
        const body_index = try self.emit(.{ .local_get = index_local }, .int);
        const element_arguments = try self.arena().alloc(Register, 2);
        element_arguments[0] = body_object;
        element_arguments[1] = body_index;
        const element = try self.emit(
            .{ .intrinsic = .{ .kind = element_kind, .arguments = element_arguments } },
            element_type,
        );
        _ = try self.emit(.{ .local_set = .{ .local = name_local, .value = element } }, .none);
        try self.loops.append(self.temporary(), .{
            .continue_block = step,
            .exit_block = exit,
            .scope_depth = self.scopes.items.len,
            .temps_depth = self.temps.items.len,
        });
        try self.lowerBlock(loop.body);
        _ = self.loops.pop();
        _ = try self.emit(.{ .jump = step }, .none);

        self.switchTo(step);
        const stepped = try self.emit(.{ .local_get = index_local }, .int);
        const one = try self.emit(.{ .const_int = 1 }, .int);
        const incremented = try self.emit(.{ .binary = .{
            .op = .add,
            .operand_type = .int,
            .left = stepped,
            .right = one,
        } }, .int);
        _ = try self.emit(.{ .local_set = .{ .local = index_local, .value = incremented } }, .none);
        _ = try self.emit(.{ .jump = header }, .none);

        self.switchTo(exit);
    }

    fn lowerReturn(self: *FunctionBuilder, returned: anytype) Error!void {
        if (returned.value) |expression| {
            const value = (try self.lowerExpression(expression, false)) orelse return;
            if (self.return_type == .none) {
                try self.fail("luce.sema.return", returned.span, "this function returns nothing", .{});
                return;
            }
            if (!value.value_type.eql(self.return_type)) {
                try self.fail("luce.sema.type", returned.span, "returning {s} from a function returning {s}", .{
                    try self.analyzer.typeName(value.value_type),
                    try self.analyzer.typeName(self.return_type),
                });
                return;
            }

            // Whatever a function returns, the caller owns (S16, S17):
            // an owned name moves out, fresh values flow out, borrows
            // are compile errors.
            var moved: ?LocalId = null;
            if (self.analyzer.carriesObjects(value.value_type)) {
                switch (expression.*) {
                    .name => |name| {
                        const found = self.findLocal(name.text).?;
                        switch (found.info.class) {
                            .owned => moved = found.info.local,
                            .borrow_param => {
                                try self.fail(
                                    "luce.sema.own",
                                    returned.span,
                                    "{s} is a borrowed parameter; return copy {s}, or take the parameter as give [OWNERSHIP.md S17]",
                                    .{ name.text, name.text },
                                );
                                return;
                            },
                            .alias => {
                                try self.fail(
                                    "luce.sema.own",
                                    returned.span,
                                    "{s} aliases an object it does not own; return copy {s} or return the owning name [OWNERSHIP.md S16, S17]",
                                    .{ name.text, name.text },
                                );
                                return;
                            },
                        }
                    },
                    else => {
                        if (!(try self.yieldsOwnership(expression))) {
                            try self.fail(
                                "luce.sema.own",
                                returned.span,
                                "this object is borrowed from a container or struct; return a copy [OWNERSHIP.md S17, S22]",
                                .{},
                            );
                            return;
                        }
                        // The fresh return value was parked as a
                        // statement temporary; un-park it so the
                        // unwinding below leaves it alone.
                        var index = self.temps.items.len;
                        while (index > 0) {
                            index -= 1;
                            if (self.temps.items[index].register == value.register) {
                                _ = self.temps.orderedRemove(index);
                                break;
                            }
                        }
                    },
                }
            }
            try self.emitTempReleases(0);
            try self.emitScopeReleases(0, moved);
            _ = try self.emit(.{ .ret = value.register }, .none);
            return;
        }
        if (self.return_type != .none) {
            try self.fail("luce.sema.return", returned.span, "return needs a {s} value", .{
                try self.analyzer.typeName(self.return_type),
            });
            return;
        }
        try self.emitTempReleases(0);
        try self.emitScopeReleases(0, null);
        _ = try self.emit(.{ .ret = null }, .none);
    }

    // Expressions ----------------------------------------------------------

    fn lowerExpression(self: *FunctionBuilder, expression: *ast.Expression, as_statement: bool) Error!?Value {
        const value = (try self.lowerExpressionInner(expression, as_statement)) orelse return null;
        // Every ownership-yielding object is parked as a statement
        // temporary (S3).  Whatever adopts it — a binding, a
        // container, a give parameter, a return — re-owns it at run
        // time, which turns the parked release into a no-op.
        if (value.value_type != .none and
            self.analyzer.carriesObjects(value.value_type) and
            try self.yieldsOwnership(expression))
        {
            try self.registerTemp(value);
        }
        return value;
    }

    fn lowerExpressionInner(self: *FunctionBuilder, expression: *ast.Expression, as_statement: bool) Error!?Value {
        switch (expression.*) {
            .int_literal => |literal| {
                const parsed = std.fmt.parseInt(i64, literal.text, 10) catch {
                    try self.fail("luce.sema.literal", literal.span, "integer literal out of range", .{});
                    return null;
                };
                return .{ .register = try self.emit(.{ .const_int = parsed }, .int), .value_type = .int };
            },
            .float_literal => |literal| {
                const parsed = std.fmt.parseFloat(f64, literal.text) catch {
                    try self.fail("luce.sema.literal", literal.span, "malformed float literal", .{});
                    return null;
                };
                return .{ .register = try self.emit(.{ .const_float = parsed }, .float), .value_type = .float };
            },
            .bool_literal => |literal| {
                return .{ .register = try self.emit(.{ .const_boolean = literal.value }, .boolean), .value_type = .boolean };
            },
            .string_literal => |literal| {
                const constant = try self.analyzer.internConstant(literal.decoded);
                return .{
                    .register = try self.emit(.{ .const_data = .{ .constant = constant, .data_type = .string } }, .string),
                    .value_type = .string,
                };
            },
            .name => |name| {
                if (std.mem.eql(u8, name.text, "input") or std.mem.eql(u8, name.text, "output")) {
                    if (self.has_frames) {
                        try self.fail("luce.sema.port", name.span, "{s} is used as {s}.PORT", .{ name.text, name.text });
                    } else {
                        try self.fail("luce.sema.name", name.span, "{s} exists only in the evaluator entry", .{name.text});
                    }
                    return null;
                }
                const found = self.findLocal(name.text) orelse {
                    // Not a local: perhaps a file-scope constant.
                    const qualified = try self.analyzer.qualify(self.prefix, name.text);
                    if (self.analyzer.constant_names.get(qualified)) |constant| {
                        return self.emitConstant(constant);
                    }
                    try self.fail("luce.sema.name", name.span, "unknown name {s}", .{name.text});
                    return null;
                };
                if (try self.checkPoisoned(found.info, name.text, name.span)) return null;
                const local = found.info.local;
                const local_type = self.locals.items[local].local_type;
                return .{ .register = try self.emit(.{ .local_get = local }, local_type), .value_type = local_type };
            },
            .field => |field| return self.lowerField(field),
            .call => |call| return self.lowerCall(call, as_statement),
            .binary => |binary| return self.lowerBinary(binary),
            .unary => |unary| return self.lowerUnary(unary),
            .method => |method| return self.lowerMethod(method, as_statement),
            .new_object => |new| return self.lowerNew(new),
            .list_literal => |literal| return self.lowerListLiteral(literal),
            .index => |index| return self.lowerIndex(index),
            .slice_range => |slice| return self.lowerSliceRange(slice),
            .give => |give| return self.lowerGive(give),
            .copy => |copied| return self.lowerCopy(copied),
        }
    }

    /// give NAME — the named object transfers to whatever receives it;
    /// the name is poisoned to the end of its scope (S10, S13, S29).
    fn lowerGive(self: *FunctionBuilder, give: anytype) Error!?Value {
        if (give.operand.* != .name) {
            try self.fail(
                "luce.sema.own",
                give.span,
                "give moves a named object; use copy for other expressions [OWNERSHIP.md S10, S31]",
                .{},
            );
            return null;
        }
        const name = give.operand.name.text;
        const found = self.findLocal(name) orelse {
            try self.fail("luce.sema.name", give.operand.name.span, "unknown name {s}", .{name});
            return null;
        };
        const info = found.info;
        const local = info.local;
        const local_type = self.locals.items[local].local_type;
        if (!info.carries) {
            try self.fail(
                "luce.sema.own",
                give.span,
                "give applies to objects (List, Map, Array, Builder, object-carrying structs), not values [OWNERSHIP.md S32]",
                .{},
            );
            return null;
        }
        if (try self.checkPoisoned(info, name, give.span)) return null;
        if (info.class == .borrow_param) {
            try self.fail(
                "luce.sema.own",
                give.span,
                "{s} is a borrowed parameter and cannot be given; take it as give in the signature, or copy it [OWNERSHIP.md S12]",
                .{name},
            );
            return null;
        }
        if (self.loops.items.len > 0 and
            found.depth < self.loops.items[self.loops.items.len - 1].scope_depth)
        {
            try self.fail(
                "luce.sema.own",
                give.span,
                "{s} is declared outside this loop; the next iteration would use a given-away name — create it fresh inside the loop, or copy [OWNERSHIP.md S30]",
                .{name},
            );
            return null;
        }
        info.poisoned = .given;
        const value = try self.emit(.{ .local_get = local }, local_type);
        const arguments = try self.arena().alloc(Register, 1);
        arguments[0] = value;
        return .{
            .register = try self.emit(
                .{ .intrinsic = .{ .kind = .give_object, .arguments = arguments } },
                local_type,
            ),
            .value_type = local_type,
        };
    }

    /// Inline a folded file-scope constant at this use site.
    fn emitConstant(self: *FunctionBuilder, index: u32) Error!?Value {
        const info = self.analyzer.constant_infos.items[index];
        if (info.state != .ready) return null; // already diagnosed
        return .{
            .register = try self.emitConstantValue(info.value, info.value_type),
            .value_type = info.value_type,
        };
    }

    fn emitConstantValue(self: *FunctionBuilder, value: ConstantValue, value_type: Type) Error!Register {
        return switch (value) {
            .int => |folded| try self.emit(.{ .const_int = folded }, .int),
            .float => |folded| try self.emit(.{ .const_float = folded }, .float),
            .boolean => |folded| try self.emit(.{ .const_boolean = folded }, .boolean),
            .string => |folded| blk: {
                const constant = try self.analyzer.internConstant(folded);
                break :blk try self.emit(
                    .{ .const_data = .{ .constant = constant, .data_type = .string } },
                    .string,
                );
            },
            .strukt => |folded| blk: {
                const layout = self.analyzer.structs.items[folded.layout];
                const fields = try self.arena().alloc(Register, folded.fields.len);
                for (folded.fields, layout.fields, fields) |field, field_layout, *slot| {
                    slot.* = try self.emitConstantValue(field, field_layout.field_type);
                }
                break :blk try self.emit(
                    .{ .struct_make = .{ .layout = folded.layout, .fields = fields } },
                    value_type,
                );
            },
        };
    }

    /// copy EXPR — a deep, independent duplicate; always legal on
    /// readable objects (S31).
    fn lowerCopy(self: *FunctionBuilder, copied: anytype) Error!?Value {
        const value = (try self.lowerExpression(copied.operand, false)) orelse return null;
        if (!self.analyzer.carriesObjects(value.value_type)) {
            try self.fail(
                "luce.sema.own",
                copied.span,
                "copy applies to objects (List, Map, Array, Builder, object-carrying structs); values copy by themselves [OWNERSHIP.md S32]",
                .{},
            );
            return null;
        }
        const arguments = try self.arena().alloc(Register, 1);
        arguments[0] = value.register;
        return .{
            .register = try self.emit(
                .{ .intrinsic = .{ .kind = .copy_object, .arguments = arguments } },
                value.value_type,
            ),
            .value_type = value.value_type,
        };
    }

    fn lowerNew(self: *FunctionBuilder, new: anytype) Error!?Value {
        var object_type: Type = undefined;
        var dims: []Register = &.{};
        if (std.mem.eql(u8, new.type_name.name, "Array")) {
            if (new.dims.len == 0 or new.dims.len > 4) {
                try self.fail("luce.sema.new", new.span, "new Array takes 1 to 4 dimension sizes: new Array(Int, 5, 5)", .{});
                return null;
            }
            const element = (try self.analyzer.resolveType(self.module, new.type_name.arguments[0])) orelse return null;
            object_type = try self.analyzer.internHeapType(.{
                .array = .{ .element = element, .rank = @intCast(new.dims.len) },
            });
            dims = try self.arena().alloc(Register, new.dims.len);
            const dimensions = (try self.lowerOperands(new.dims)) orelse return null;
            for (dimensions, new.dims, dims) |dimension, expression, *register| {
                if (dimension.value_type != .int) {
                    try self.fail("luce.sema.new", expression.span(), "array dimensions are Int", .{});
                    return null;
                }
                register.* = dimension.register;
            }
        } else {
            object_type = (try self.analyzer.resolveType(self.module, new.type_name)) orelse return null;
            if (object_type != .heap) {
                try self.fail("luce.sema.new", new.span, "new builds List, Map, Array, or Builder", .{});
                return null;
            }
        }
        return .{
            .register = try self.emit(.{ .heap_new = .{ .heap = object_type.heap, .dims = dims } }, object_type),
            .value_type = object_type,
        };
    }

    fn lowerListLiteral(self: *FunctionBuilder, literal: anytype) Error!?Value {
        if (literal.elements.len == 0) {
            try self.fail(
                "luce.sema.type",
                literal.span,
                "an empty [] needs an annotated binding (var xs: List(Int) = []) or new List(T)",
                .{},
            );
            return null;
        }
        const elements = (try self.lowerOperands(literal.elements)) orelse return null;
        for (elements, literal.elements) |element, expression| {
            if (!element.value_type.eql(elements[0].value_type)) {
                try self.fail("luce.sema.type", expression.span(), "list elements are all {s}, got {s}", .{
                    try self.analyzer.typeName(elements[0].value_type),
                    try self.analyzer.typeName(element.value_type),
                });
                return null;
            }
        }
        const object_type = try self.analyzer.internHeapType(.{ .list = elements[0].value_type });
        const list = try self.emit(.{ .heap_new = .{ .heap = object_type.heap, .dims = &.{} } }, object_type);
        for (elements) |element| {
            const arguments = try self.arena().alloc(Register, 2);
            arguments[0] = list;
            arguments[1] = element.register;
            _ = try self.emit(.{ .intrinsic = .{ .kind = .append_value, .arguments = arguments } }, .none);
        }
        return .{ .register = list, .value_type = object_type };
    }

    fn lowerIndex(self: *FunctionBuilder, index: anytype) Error!?Value {
        const expressions = try self.arena().alloc(*ast.Expression, index.indices.len + 1);
        expressions[0] = index.target;
        @memcpy(expressions[1..], index.indices);
        const values = (try self.lowerOperands(expressions)) orelse return null;
        const element_type = (try self.checkIndex(values[0], values[1..], index.span)) orelse return null;
        const arguments = try self.arena().alloc(Register, values.len);
        for (values, arguments) |value, *slot| slot.* = value.register;
        return .{
            .register = try self.emit(
                .{ .intrinsic = .{ .kind = .index_get, .arguments = arguments } },
                element_type,
            ),
            .value_type = element_type,
        };
    }

    fn lowerSliceRange(self: *FunctionBuilder, slice: anytype) Error!?Value {
        var whole_sequence: std.ArrayList(*ast.Expression) = .empty;
        defer whole_sequence.deinit(self.temporary());
        try whole_sequence.append(self.temporary(), slice.target);
        if (slice.start) |expression| try whole_sequence.append(self.temporary(), expression);
        if (slice.end) |expression| try whole_sequence.append(self.temporary(), expression);
        const sequence = (try self.lowerOperands(whole_sequence.items)) orelse return null;
        const target = sequence[0];
        const is_string = target.value_type == .string;
        const descriptor = self.analyzer.heapOf(target.value_type);
        if (!is_string and (descriptor == null or descriptor.? != .list)) {
            try self.fail("luce.sema.index", slice.span, "{s} cannot be sliced; slices work on List and String", .{
                try self.analyzer.typeName(target.value_type),
            });
            return null;
        }

        const lowered_bounds = sequence[1..];
        for (lowered_bounds) |value| {
            if (value.value_type != .int) {
                try self.fail("luce.sema.type", slice.span, "slice bounds are Int", .{});
                return null;
            }
        }
        var next_bound: usize = 0;
        var start: Register = undefined;
        if (slice.start != null) {
            start = lowered_bounds[next_bound].register;
            next_bound += 1;
        } else {
            start = try self.emit(.{ .const_int = 0 }, .int);
        }
        var end: Register = undefined;
        if (slice.end != null) {
            end = lowered_bounds[next_bound].register;
        } else {
            const whole = try self.arena().alloc(Register, 1);
            whole[0] = target.register;
            end = try self.emit(.{ .intrinsic = .{ .kind = .len, .arguments = whole } }, .int);
        }

        const arguments = try self.arena().alloc(Register, 3);
        arguments[0] = target.register;
        arguments[1] = start;
        arguments[2] = end;
        const kind: ir.Intrinsic = if (is_string) .string_slice else .list_slice;
        return .{
            .register = try self.emit(.{ .intrinsic = .{ .kind = kind, .arguments = arguments } }, target.value_type),
            .value_type = target.value_type,
        };
    }

    fn lowerField(self: *FunctionBuilder, field: anytype) Error!?Value {
        // input.NAME reads a port; anything else reads a struct field.
        if (field.target.* == .name) {
            const base = field.target.name.text;
            if (std.mem.eql(u8, base, "input")) {
                if (!self.has_frames) {
                    try self.fail("luce.sema.name", field.span, "input exists only in the evaluator entry", .{});
                    return null;
                }
                const port = self.analyzer.schema.findInput(field.name) orelse {
                    try self.fail("luce.sema.port", field.span, "no input port named {s}", .{field.name});
                    return null;
                };
                try self.analyzer.reads.put(self.analyzer.temporary, port, {});
                const port_type = Type.fromPort(self.analyzer.schema.inputs[port].declared);
                return .{ .register = try self.emit(.{ .input_load = port }, port_type), .value_type = port_type };
            }
            if (std.mem.eql(u8, base, "output")) {
                if (self.has_frames) {
                    try self.fail("luce.sema.output", field.span, "output ports are write-only", .{});
                } else {
                    try self.fail("luce.sema.name", field.span, "output exists only in the evaluator entry", .{});
                }
                return null;
            }
            // geo.pi — an imported module's file-scope constant.
            if (self.findLocal(base) == null and self.analyzer.importsModule(self.module, base)) {
                const joined = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ base, field.name });
                if (self.analyzer.constant_names.get(joined)) |constant| {
                    return self.emitConstant(constant);
                }
            }
        }
        const target = (try self.lowerExpression(field.target, false)) orelse return null;
        if (target.value_type != .strukt) {
            try self.fail("luce.sema.field", field.span, "{s} has no fields", .{
                try self.analyzer.typeName(target.value_type),
            });
            return null;
        }
        const layout_index = target.value_type.strukt;
        const layout = self.analyzer.structs.items[layout_index];
        const field_index = layout.findField(field.name) orelse {
            try self.fail("luce.sema.field", field.span, "{s} has no field {s}", .{ layout.name, field.name });
            return null;
        };
        const field_type = layout.fields[field_index].field_type;
        return .{
            .register = try self.emit(.{ .struct_get = .{
                .target = target.register,
                .layout = layout_index,
                .field = field_index,
            } }, field_type),
            .value_type = field_type,
        };
    }

    fn lowerBinary(self: *FunctionBuilder, binary: anytype) Error!?Value {
        switch (binary.op) {
            .logic_and, .logic_or => return self.lowerShortCircuit(binary),
            else => {},
        }
        const sides = (try self.lowerOperands(&.{ binary.left, binary.right })) orelse return null;
        const left = sides[0];
        const right = sides[1];
        if (!left.value_type.eql(right.value_type)) {
            try self.fail("luce.sema.type", binary.span, "operands are {s} and {s} (conversions are explicit)", .{
                try self.analyzer.typeName(left.value_type),
                try self.analyzer.typeName(right.value_type),
            });
            return null;
        }
        const operand_type = left.value_type;

        const operation: ir.BinaryOp = switch (binary.op) {
            .add => .add,
            .subtract => .subtract,
            .multiply => .multiply,
            .divide => .divide,
            .remainder => .remainder,
            .equal => .equal,
            .not_equal => .not_equal,
            .less => .less,
            .less_equal => .less_equal,
            .greater => .greater,
            .greater_equal => .greater_equal,
            .logic_and, .logic_or => unreachable,
        };

        const arithmetic = switch (operation) {
            .add, .subtract, .multiply, .divide, .remainder => true,
            else => false,
        };
        if (arithmetic) {
            const string_concat = operation == .add and operand_type == .string;
            if (!operand_type.isNumeric() and !string_concat) {
                try self.fail("luce.sema.type", binary.span, "{s} does not support this operator", .{
                    try self.analyzer.typeName(operand_type),
                });
                return null;
            }
            return .{
                .register = try self.emit(.{ .binary = .{
                    .op = operation,
                    .operand_type = operand_type,
                    .left = left.register,
                    .right = right.register,
                } }, operand_type),
                .value_type = operand_type,
            };
        }

        // Comparisons: equality everywhere; ordering for Int, Float,
        // and String.
        const ordering = operation != .equal and operation != .not_equal;
        if (ordering and !(operand_type.isNumeric() or operand_type == .string)) {
            try self.fail("luce.sema.type", binary.span, "{s} has no ordering", .{
                try self.analyzer.typeName(operand_type),
            });
            return null;
        }
        if (operand_type == .none) {
            try self.fail("luce.sema.type", binary.span, "value has no type", .{});
            return null;
        }
        return .{
            .register = try self.emit(.{ .binary = .{
                .op = operation,
                .operand_type = operand_type,
                .left = left.register,
                .right = right.register,
            } }, .boolean),
            .value_type = .boolean,
        };
    }

    fn lowerShortCircuit(self: *FunctionBuilder, binary: anytype) Error!?Value {
        const left = (try self.lowerExpression(binary.left, false)) orelse return null;
        if (left.value_type != .boolean) {
            try self.fail("luce.sema.type", binary.span, "{s} needs Bool operands", .{
                if (binary.op == .logic_and) @as([]const u8, "and") else "or",
            });
            return null;
        }
        const result_local = try self.hiddenLocal(.boolean);
        _ = try self.emit(.{ .local_set = .{ .local = result_local, .value = left.register } }, .none);

        const evaluate_right = try self.reserveBlock();
        const merge = try self.reserveBlock();
        if (binary.op == .logic_and) {
            _ = try self.emit(.{ .branch = .{
                .condition = left.register,
                .then_block = evaluate_right,
                .else_block = merge,
            } }, .none);
        } else {
            _ = try self.emit(.{ .branch = .{
                .condition = left.register,
                .then_block = merge,
                .else_block = evaluate_right,
            } }, .none);
        }

        self.switchTo(evaluate_right);
        if (try self.lowerExpression(binary.right, false)) |right| {
            if (right.value_type != .boolean) {
                try self.fail("luce.sema.type", binary.span, "{s} needs Bool operands", .{
                    if (binary.op == .logic_and) @as([]const u8, "and") else "or",
                });
            } else {
                _ = try self.emit(.{ .local_set = .{ .local = result_local, .value = right.register } }, .none);
            }
        }
        _ = try self.emit(.{ .jump = merge }, .none);

        self.switchTo(merge);
        return .{
            .register = try self.emit(.{ .local_get = result_local }, .boolean),
            .value_type = .boolean,
        };
    }

    fn lowerUnary(self: *FunctionBuilder, unary: anytype) Error!?Value {
        const operand = (try self.lowerExpression(unary.operand, false)) orelse return null;
        switch (unary.op) {
            .negate => {
                if (!operand.value_type.isNumeric()) {
                    try self.fail("luce.sema.type", unary.span, "cannot negate {s}", .{
                        try self.analyzer.typeName(operand.value_type),
                    });
                    return null;
                }
                return .{
                    .register = try self.emit(.{ .unary = .{ .op = .negate, .operand = operand.register } }, operand.value_type),
                    .value_type = operand.value_type,
                };
            },
            .logic_not => {
                if (operand.value_type != .boolean) {
                    try self.fail("luce.sema.type", unary.span, "not needs a Bool", .{});
                    return null;
                }
                return .{
                    .register = try self.emit(.{ .unary = .{ .op = .logic_not, .operand = operand.register } }, .boolean),
                    .value_type = .boolean,
                };
            },
        }
    }

    // Calls: struct construction, explicit conversion, intrinsics,
    // and user functions.
    fn lowerCall(self: *FunctionBuilder, call: anytype, as_statement: bool) Error!?Value {
        // Builtins and conversions are bare names and take priority;
        // reserved names keep user declarations out of their way.
        if (std.mem.indexOfScalar(u8, call.callee, '.') == null) {
            if (std.mem.eql(u8, call.callee, "Int") or std.mem.eql(u8, call.callee, "Float")) {
                return self.lowerConvert(call);
            }
            switch (try self.lowerIntrinsic(call, as_statement)) {
                .not_builtin => {},
                .failed => return null,
                .value => |value| return value,
            }
        }

        const resolved = (try self.resolveDeclared(call.callee, call.span)) orelse return null;
        if (self.analyzer.struct_names.get(resolved)) |layout_index| {
            return self.lowerConstruct(call, layout_index);
        }
        const function_index = self.analyzer.function_names.get(resolved) orelse {
            try self.fail("luce.sema.call", call.span, "unknown function {s}", .{call.callee});
            return null;
        };
        return self.lowerUserCall(function_index, call.callee, call.arguments, call.span, as_statement);
    }

    fn lowerUserCall(
        self: *FunctionBuilder,
        function_index: u32,
        name: []const u8,
        call_arguments: []const ast.Argument,
        span: Span,
        as_statement: bool,
    ) Error!?Value {
        const info = self.analyzer.functions.items[function_index];
        if (info.is_entry) {
            try self.fail("luce.sema.call", span, "entry function {s} cannot be called", .{name});
            return null;
        }
        if (call_arguments.len != info.parameter_types.len) {
            try self.fail("luce.sema.call", span, "{s} takes {d} arguments, got {d}", .{
                name,
                info.parameter_types.len,
                call_arguments.len,
            });
            return null;
        }
        const expressions = try self.arena().alloc(*ast.Expression, call_arguments.len);
        for (call_arguments, expressions) |argument, *slot| {
            if (argument.name != null) {
                try self.fail("luce.sema.call", argument.span, "function arguments are positional", .{});
                return null;
            }
            slot.* = argument.value;
        }
        // Ownership handoffs are never invisible: a give parameter
        // needs give NAME, copy NAME, or something fresh at the call
        // site; a borrow parameter refuses a give (S13, S14).
        for (expressions, 0..) |argument, index| {
            if (index >= info.parameter_modes.len) break;
            if (info.parameter_modes[index] == .give) {
                if (!(try self.yieldsOwnership(argument))) {
                    try self.fail(
                        "luce.sema.own",
                        call_arguments[index].span,
                        "argument {d} of {s} takes ownership; write give NAME, copy NAME, or pass something fresh [OWNERSHIP.md S13, S14]",
                        .{ index + 1, name },
                    );
                    return null;
                }
            } else if (argument.* == .give) {
                try self.fail(
                    "luce.sema.own",
                    call_arguments[index].span,
                    "{s} only borrows this argument; give needs a give parameter in the signature [OWNERSHIP.md S11, S13]",
                    .{name},
                );
                return null;
            }
        }
        const values = (try self.lowerOperands(expressions)) orelse return null;
        const registers = try self.arena().alloc(Register, call_arguments.len);
        for (values, 0..) |value, index| {
            if (!value.value_type.eql(info.parameter_types[index])) {
                try self.fail("luce.sema.type", call_arguments[index].span, "argument {d} of {s} is {s}, got {s}", .{
                    index + 1,
                    name,
                    try self.analyzer.typeName(info.parameter_types[index]),
                    try self.analyzer.typeName(value.value_type),
                });
                return null;
            }
            registers[index] = value.register;
        }
        if (info.return_type == .none and !as_statement) {
            try self.fail("luce.sema.call", span, "{s} returns nothing", .{name});
            return null;
        }
        return .{
            .register = try self.emit(.{ .call = .{ .function = function_index, .arguments = registers } }, info.return_type),
            .value_type = info.return_type,
        };
    }

    /// target.name(args): a namespaced call when the target chain is
    /// bare declaration names (Struct.func, module.func,
    /// module.Struct(...) construction), otherwise a builtin method on
    /// the target value.  Locals shadow nothing, so a chain whose head
    /// is a local is always a value method.
    fn lowerMethod(self: *FunctionBuilder, method: anytype, as_statement: bool) Error!?Value {
        switch (try self.methodNamespace(method)) {
            .resolved => |resolved| {
                if (self.analyzer.struct_names.get(resolved)) |layout_index| {
                    return self.lowerConstruct(method, layout_index);
                }
                const function_index = self.analyzer.function_names.get(resolved).?;
                return self.lowerUserCall(function_index, resolved, method.arguments, method.span, as_statement);
            },
            .reported => return null,
            .value => return self.lowerValueMethod(method, as_statement),
        }
    }

    const NamespaceResolution = union(enum) {
        /// Not a namespace: lower as a method on a value.
        value,
        /// A namespace whose member is missing; already diagnosed.
        reported,
        /// The fully-qualified declaration this call names.
        resolved: []const u8,
    };

    /// Decide whether target.name(...) names a declaration.
    fn methodNamespace(self: *FunctionBuilder, method: anytype) Error!NamespaceResolution {
        // Collect the dotted chain of bare names in front of the call.
        var parts: [3][]const u8 = undefined;
        var count: usize = 0;
        var walk: *const ast.Expression = method.target;
        while (true) {
            switch (walk.*) {
                .name => |name| {
                    if (count == 3) return .value;
                    parts[count] = name.text;
                    count += 1;
                    break;
                },
                .field => |field| {
                    if (count == 3) return .value;
                    parts[count] = field.name;
                    count += 1;
                    walk = field.target;
                },
                else => return .value,
            }
        }
        // parts collected inner-to-outer; the head is the last one.
        const head = parts[count - 1];
        if (self.findLocal(head) != null) return .value;

        var written: std.ArrayList(u8) = .empty;
        defer written.deinit(self.temporary());
        var at = count;
        while (at > 0) {
            at -= 1;
            try written.appendSlice(self.temporary(), parts[at]);
            try written.append(self.temporary(), '.');
        }
        try written.appendSlice(self.temporary(), method.name);

        // Two namespace shapes exist: a struct of this module
        // (Words.classify) and an imported module (geo.helper,
        // geo.Point, geo.Text.width).  A head that names neither is a
        // value; a head that names one but whose member is missing is
        // a call error, not a method fallback.
        const joined = written.items;
        const head_qualified = try self.analyzer.qualify(self.prefix, head);
        if (self.analyzer.struct_names.contains(head_qualified)) {
            const local = try self.analyzer.qualify(self.prefix, joined);
            if (self.analyzer.struct_names.contains(local) or self.analyzer.function_names.contains(local)) {
                return .{ .resolved = try self.arena().dupe(u8, local) };
            }
            try self.fail("luce.sema.call", method.span, "unknown function {s}", .{joined});
            return .reported;
        }
        if (self.analyzer.importsModule(self.module, head)) {
            if (self.analyzer.struct_names.contains(joined) or self.analyzer.function_names.contains(joined)) {
                return .{ .resolved = try self.arena().dupe(u8, joined) };
            }
            // geo.pi.method() — a value method on an imported constant.
            if (count >= 2) {
                const member = try std.fmt.allocPrint(self.temporary(), "{s}.{s}", .{ head, parts[count - 2] });
                defer self.temporary().free(member);
                if (self.analyzer.constant_names.contains(member)) return .value;
            }
            try self.fail("luce.sema.call", method.span, "unknown function {s}", .{joined});
            return .reported;
        }
        // The head names a module elsewhere in this program: point at
        // the missing import instead of "unknown name".
        for (self.analyzer.modules) |module| {
            if (module.prefix.len != 0 and std.mem.eql(u8, module.prefix, head)) {
                try self.fail("luce.sema.import", method.span, "unknown namespace {s}; import {s} to use it", .{ head, head });
                return .reported;
            }
        }
        return .value;
    }

    /// Builtin methods on values: strings, lists, arrays, maps, and
    /// builders.  `x.f(y)` is sugar for a plain typed operation with
    /// the receiver first — there is no dispatch.
    fn lowerValueMethod(self: *FunctionBuilder, method: anytype, as_statement: bool) Error!?Value {
        if (method.arguments.len > 2) {
            try self.fail("luce.sema.method", method.span, "no method takes more than 2 arguments", .{});
            return null;
        }
        var expressions: [3]*ast.Expression = undefined;
        expressions[0] = method.target;
        for (method.arguments, 0..) |argument, index| {
            if (argument.name != null) {
                try self.fail("luce.sema.method", argument.span, "method arguments are positional", .{});
                return null;
            }
            expressions[index + 1] = argument.value;
        }
        const values = (try self.lowerOperands(expressions[0 .. method.arguments.len + 1])) orelse
            return null;
        const receiver = values[0];
        const arguments = values[1..];

        const found: MethodFound = blk: {
            if (receiver.value_type == .string) {
                if (try self.stringMethod(method, arguments)) |found| break :blk found;
                return null;
            }
            if (self.analyzer.heapOf(receiver.value_type)) |descriptor| {
                if (try self.objectMethod(method, receiver.value_type, descriptor, arguments)) |found| {
                    break :blk found;
                }
                return null;
            }
            try self.fail("luce.sema.method", method.span, "{s} has no methods", .{
                try self.analyzer.typeName(receiver.value_type),
            });
            return null;
        };

        if (found.result == .none and !as_statement) {
            try self.fail("luce.sema.method", method.span, "{s} returns nothing", .{method.name});
            return null;
        }
        // Containers own their object elements: append/insert take a
        // fresh value, a give, or a copy (S20, S21).
        if (found.kind == .append_value or found.kind == .insert_value) {
            if (self.analyzer.heapOf(receiver.value_type)) |descriptor| {
                if (descriptor == .list and self.analyzer.carriesObjects(descriptor.list)) {
                    const value_index: usize = if (found.kind == .append_value) 0 else 1;
                    if (!(try self.yieldsOwnership(method.arguments[value_index].value))) {
                        try self.fail(
                            "luce.sema.own",
                            method.arguments[value_index].span,
                            "a container keeps its object elements; store something fresh, give NAME, or copy NAME [OWNERSHIP.md S21]",
                            .{},
                        );
                        return null;
                    }
                }
            }
        }
        const registers = try self.arena().alloc(Register, values.len);
        for (values, registers) |value, *slot| slot.* = value.register;
        return .{
            .register = try self.emit(.{ .intrinsic = .{ .kind = found.kind, .arguments = registers } }, found.result),
            .value_type = found.result,
        };
    }

    const MethodFound = struct { kind: ir.Intrinsic, result: Type };

    fn methodFail(self: *FunctionBuilder, method: anytype, comptime message: []const u8) Error!?MethodFound {
        try self.fail("luce.sema.method", method.span, message, .{});
        return null;
    }

    fn stringMethod(self: *FunctionBuilder, method: anytype, arguments: []const Value) Error!?MethodFound {
        const name = method.name;
        const Simple = struct { name: []const u8, kind: ir.Intrinsic, takes: usize, argument: Type, result: Type };
        const table = [_]Simple{
            .{ .name = "find", .kind = .str_find, .takes = 1, .argument = .string, .result = .int },
            .{ .name = "contains", .kind = .str_contains, .takes = 1, .argument = .string, .result = .boolean },
            .{ .name = "starts_with", .kind = .str_starts, .takes = 1, .argument = .string, .result = .boolean },
            .{ .name = "ends_with", .kind = .str_ends, .takes = 1, .argument = .string, .result = .boolean },
            .{ .name = "trim", .kind = .str_trim, .takes = 0, .argument = .none, .result = .string },
            .{ .name = "lower", .kind = .str_lower, .takes = 0, .argument = .none, .result = .string },
            .{ .name = "upper", .kind = .str_upper, .takes = 0, .argument = .none, .result = .string },
            .{ .name = "repeat", .kind = .str_repeat, .takes = 1, .argument = .int, .result = .string },
            .{ .name = "byte_at", .kind = .string_byte, .takes = 1, .argument = .int, .result = .int },
        };
        for (table) |entry| {
            if (!std.mem.eql(u8, name, entry.name)) continue;
            if (arguments.len != entry.takes) {
                try self.fail("luce.sema.method", method.span, "{s} takes {d} argument{s}", .{
                    entry.name,
                    entry.takes,
                    if (entry.takes == 1) "" else "s",
                });
                return null;
            }
            if (entry.takes == 1 and !arguments[0].value_type.eql(entry.argument)) {
                try self.fail("luce.sema.method", method.span, "{s} takes {s}", .{
                    entry.name,
                    try self.analyzer.typeName(entry.argument),
                });
                return null;
            }
            return .{ .kind = entry.kind, .result = entry.result };
        }
        if (std.mem.eql(u8, name, "replace")) {
            if (arguments.len != 2 or arguments[0].value_type != .string or arguments[1].value_type != .string)
                return self.methodFail(method, "replace takes (old String, new String)");
            return .{ .kind = .str_replace, .result = .string };
        }
        if (std.mem.eql(u8, name, "split")) {
            if (arguments.len != 1 or arguments[0].value_type != .string)
                return self.methodFail(method, "split takes a String separator (empty splits on whitespace)");
            return .{ .kind = .str_split, .result = try self.analyzer.internHeapType(.{ .list = .string }) };
        }
        try self.fail("luce.sema.method", method.span, "String has no method {s}", .{name});
        return null;
    }

    fn objectMethod(
        self: *FunctionBuilder,
        method: anytype,
        receiver_type: Type,
        descriptor: types.HeapType,
        arguments: []const Value,
    ) Error!?MethodFound {
        _ = receiver_type;
        const name = method.name;
        switch (descriptor) {
            .list => |element| return self.sequenceMethod(method, element, true, arguments),
            .array => |shape| {
                if (std.mem.eql(u8, name, "dim")) {
                    if (arguments.len != 1 or arguments[0].value_type != .int)
                        return self.methodFail(method, "dim takes an Int axis");
                    return .{ .kind = .dim_size, .result = .int };
                }
                if (std.mem.eql(u8, name, "fill")) {
                    if (arguments.len != 1 or !arguments[0].value_type.eql(shape.element))
                        return self.methodFail(method, "fill takes one element value");
                    return .{ .kind = .array_fill, .result = .none };
                }
                if (shape.rank != 1) {
                    try self.fail("luce.sema.method", method.span, "only rank-1 arrays have {s}; index higher ranks", .{name});
                    return null;
                }
                return self.sequenceMethod(method, shape.element, false, arguments);
            },
            .map => |pair| {
                if (std.mem.eql(u8, name, "has")) {
                    if (arguments.len != 1 or !arguments[0].value_type.eql(pair.key))
                        return self.methodFail(method, "has takes the map's key type");
                    return .{ .kind = .has_key, .result = .boolean };
                }
                if (std.mem.eql(u8, name, "remove")) {
                    if (arguments.len != 1 or !arguments[0].value_type.eql(pair.key))
                        return self.methodFail(method, "remove takes the map's key type");
                    return .{ .kind = .remove_entry, .result = .none };
                }
                if (std.mem.eql(u8, name, "keys")) {
                    if (arguments.len != 0) return self.methodFail(method, "keys takes no arguments");
                    return .{ .kind = .map_keys, .result = try self.analyzer.internHeapType(.{ .list = pair.key }) };
                }
                if (std.mem.eql(u8, name, "clear")) {
                    if (arguments.len != 0) return self.methodFail(method, "clear takes no arguments");
                    return .{ .kind = .clear_object, .result = .none };
                }
                try self.fail("luce.sema.method", method.span, "Map has no method {s}", .{name});
                return null;
            },
            .builder => {
                if (std.mem.eql(u8, name, "append")) {
                    if (arguments.len != 1 or arguments[0].value_type != .string)
                        return self.methodFail(method, "a Builder appends String");
                    return .{ .kind = .append_value, .result = .none };
                }
                if (std.mem.eql(u8, name, "clear")) {
                    if (arguments.len != 0) return self.methodFail(method, "clear takes no arguments");
                    return .{ .kind = .clear_object, .result = .none };
                }
                try self.fail("luce.sema.method", method.span, "Builder has no method {s}", .{name});
                return null;
            },
        }
    }

    /// Methods shared by List and rank-1 Array; growth operations are
    /// list-only.
    fn sequenceMethod(
        self: *FunctionBuilder,
        method: anytype,
        element: Type,
        growable: bool,
        arguments: []const Value,
    ) Error!?MethodFound {
        const name = method.name;
        if (growable) {
            if (std.mem.eql(u8, name, "append")) {
                if (arguments.len != 1 or !arguments[0].value_type.eql(element))
                    return self.methodFail(method, "append takes one element value");
                return .{ .kind = .append_value, .result = .none };
            }
            if (std.mem.eql(u8, name, "insert")) {
                if (arguments.len != 2 or arguments[0].value_type != .int or
                    !arguments[1].value_type.eql(element))
                    return self.methodFail(method, "insert takes (index Int, value)");
                return .{ .kind = .insert_value, .result = .none };
            }
            if (std.mem.eql(u8, name, "remove")) {
                if (arguments.len != 1 or arguments[0].value_type != .int)
                    return self.methodFail(method, "remove takes an Int index");
                return .{ .kind = .remove_entry, .result = .none };
            }
            if (std.mem.eql(u8, name, "pop")) {
                if (arguments.len != 0) return self.methodFail(method, "pop takes no arguments");
                return .{ .kind = .pop_value, .result = element };
            }
            if (std.mem.eql(u8, name, "clear")) {
                if (arguments.len != 0) return self.methodFail(method, "clear takes no arguments");
                return .{ .kind = .clear_object, .result = .none };
            }
            if (std.mem.eql(u8, name, "join")) {
                if (element != .string) return self.methodFail(method, "join works on List(String)");
                if (arguments.len != 1 or arguments[0].value_type != .string)
                    return self.methodFail(method, "join takes a String separator");
                return .{ .kind = .list_join, .result = .string };
            }
        }
        if (std.mem.eql(u8, name, "sort")) {
            if (arguments.len != 0) return self.methodFail(method, "sort takes no arguments");
            const ordered = element == .int or element == .float or element == .string;
            if (!ordered) return self.methodFail(method, "sort orders Int, Float, or String elements");
            return .{ .kind = .list_sort, .result = .none };
        }
        if (std.mem.eql(u8, name, "reverse")) {
            if (arguments.len != 0) return self.methodFail(method, "reverse takes no arguments");
            return .{ .kind = .list_reverse, .result = .none };
        }
        if (std.mem.eql(u8, name, "find")) {
            if (arguments.len != 1 or !arguments[0].value_type.eql(element))
                return self.methodFail(method, "find takes one element value");
            return .{ .kind = .list_find, .result = .int };
        }
        if (std.mem.eql(u8, name, "contains")) {
            if (arguments.len != 1 or !arguments[0].value_type.eql(element))
                return self.methodFail(method, "contains takes one element value");
            return .{ .kind = .list_contains, .result = .boolean };
        }
        try self.fail("luce.sema.method", method.span, "no method {s} here (append insert remove pop sort reverse find contains clear join)", .{name});
        return null;
    }

    fn lowerConstruct(self: *FunctionBuilder, call: anytype, layout_index: u32) Error!?Value {
        const layout = self.analyzer.structs.items[layout_index];
        if (layout.fields.len == 0) {
            try self.fail(
                "luce.sema.construct",
                call.span,
                "{s} is a function namespace and has no value fields",
                .{layout.name},
            );
            return null;
        }
        const registers = try self.arena().alloc(Register, layout.fields.len);
        var seen = try self.temporary().alloc(bool, layout.fields.len);
        defer self.temporary().free(seen);
        @memset(seen, false);

        const expressions = try self.arena().alloc(*ast.Expression, call.arguments.len);
        for (call.arguments, expressions) |argument, *slot| slot.* = argument.value;
        const values = (try self.lowerOperands(expressions)) orelse return null;
        for (call.arguments, values) |argument, value| {
            const name = argument.name orelse {
                try self.fail("luce.sema.construct", argument.span, "{s} is built with named fields: {s}(field = ...)", .{ layout.name, layout.name });
                return null;
            };
            const field_index = layout.findField(name) orelse {
                try self.fail("luce.sema.construct", argument.span, "{s} has no field {s}", .{ layout.name, name });
                return null;
            };
            if (seen[field_index]) {
                try self.fail("luce.sema.construct", argument.span, "field {s} given twice", .{name});
                return null;
            }
            const expected = layout.fields[field_index].field_type;
            if (!value.value_type.eql(expected)) {
                try self.fail("luce.sema.type", argument.span, "{s}.{s} is {s}, got {s}", .{
                    layout.name,
                    name,
                    try self.analyzer.typeName(expected),
                    try self.analyzer.typeName(value.value_type),
                });
                return null;
            }
            // Object fields follow the verb rule at construction
            // (S24): the binding that receives the struct owns them.
            if (self.analyzer.carriesObjects(expected) and
                !(try self.yieldsOwnership(argument.value)))
            {
                try self.fail(
                    "luce.sema.own",
                    argument.span,
                    "{s}.{s} keeps its object; construct with something fresh, give NAME, or copy NAME [OWNERSHIP.md S21, S24]",
                    .{ layout.name, name },
                );
                return null;
            }
            seen[field_index] = true;
            registers[field_index] = value.register;
        }
        for (seen, 0..) |given, index| {
            if (!given) {
                try self.fail("luce.sema.construct", call.span, "{s} is missing field {s}", .{
                    layout.name,
                    layout.fields[index].name,
                });
                return null;
            }
        }
        const result_type: Type = .{ .strukt = layout_index };
        return .{
            .register = try self.emit(.{ .struct_make = .{ .layout = layout_index, .fields = registers } }, result_type),
            .value_type = result_type,
        };
    }

    fn lowerConvert(self: *FunctionBuilder, call: anytype) Error!?Value {
        if (call.arguments.len != 1 or call.arguments[0].name != null) {
            try self.fail("luce.sema.convert", call.span, "{s}(value) takes one argument", .{call.callee});
            return null;
        }
        const value = (try self.lowerExpression(call.arguments[0].value, false)) orelse return null;
        const to_int = std.mem.eql(u8, call.callee, "Int");
        if (to_int) {
            if (value.value_type == .int) return value;
            if (value.value_type != .float) {
                try self.fail("luce.sema.convert", call.span, "Int() converts Float, not {s}", .{
                    try self.analyzer.typeName(value.value_type),
                });
                return null;
            }
            return .{
                .register = try self.emit(.{ .convert = .{ .kind = .float_to_int, .operand = value.register } }, .int),
                .value_type = .int,
            };
        }
        if (value.value_type == .float) return value;
        if (value.value_type != .int) {
            try self.fail("luce.sema.convert", call.span, "Float() converts Int, not {s}", .{
                try self.analyzer.typeName(value.value_type),
            });
            return null;
        }
        return .{
            .register = try self.emit(.{ .convert = .{ .kind = .int_to_float, .operand = value.register } }, .float),
            .value_type = .float,
        };
    }

    const IntrinsicResult = union(enum) {
        not_builtin,
        failed,
        value: Value,
    };

    /// Lower a builtin call; .not_builtin when the callee is no
    /// builtin, .failed after reporting bad arguments.
    fn lowerIntrinsic(self: *FunctionBuilder, call: anytype, as_statement: bool) Error!IntrinsicResult {
        const Builtin = struct {
            name: []const u8,
            kind: ir.Intrinsic,
            arity: usize,
            host: bool = false,
            fabric: bool = false,
        };
        const builtins = [_]Builtin{
            .{ .name = "abs", .kind = .abs, .arity = 1 },
            .{ .name = "min", .kind = .min, .arity = 2 },
            .{ .name = "max", .kind = .max, .arity = 2 },
            .{ .name = "clamp", .kind = .clamp, .arity = 3 },
            .{ .name = "sqrt", .kind = .sqrt, .arity = 1 },
            .{ .name = "floor", .kind = .floor, .arity = 1 },
            .{ .name = "ceil", .kind = .ceil, .arity = 1 },
            .{ .name = "len", .kind = .len, .arity = 1 },
            .{ .name = "assert", .kind = .assert_true, .arity = 1 },
            .{ .name = "trap", .kind = .trap_message, .arity = 1 },
            .{ .name = "free", .kind = .free_object, .arity = 1 },
            .{ .name = "str", .kind = .str_value, .arity = 1 },
            .{ .name = "parse_int", .kind = .parse_int, .arity = 1 },
            .{ .name = "parse_float", .kind = .parse_float, .arity = 1 },
            .{ .name = "chr", .kind = .chr_code, .arity = 1 },
            .{ .name = "ord", .kind = .ord_text, .arity = 1 },
            .{ .name = "print", .kind = .print, .arity = 1, .host = true },
            .{ .name = "file_read", .kind = .file_read, .arity = 1, .host = true },
            .{ .name = "file_write", .kind = .file_write, .arity = 2, .host = true },
            .{ .name = "file_exists", .kind = .file_exists, .arity = 1, .host = true },
            .{ .name = "arg_count", .kind = .arg_count, .arity = 0, .host = true },
            .{ .name = "arg", .kind = .arg_get, .arity = 1, .host = true },
            .{ .name = "term_rows", .kind = .term_rows, .arity = 0, .host = true },
            .{ .name = "term_cols", .kind = .term_cols, .arity = 0, .host = true },
            .{ .name = "term_clear", .kind = .term_clear, .arity = 0, .host = true },
            .{ .name = "term_move", .kind = .term_move, .arity = 2, .host = true },
            .{ .name = "term_style", .kind = .term_style, .arity = 3, .host = true },
            .{ .name = "term_write", .kind = .term_write, .arity = 1, .host = true },
            .{ .name = "term_flush", .kind = .term_flush, .arity = 0, .host = true },
            .{ .name = "key_read", .kind = .key_read, .arity = 0, .host = true },
            .{ .name = "key_text", .kind = .key_text, .arity = 0, .host = true },
            .{ .name = "create_image", .kind = .fabric_image, .arity = 2, .fabric = true },
            .{ .name = "create_texel", .kind = .fabric_create, .arity = 1, .fabric = true },
            .{ .name = "texel_input", .kind = .fabric_input, .arity = 3, .fabric = true },
            .{ .name = "texel_output", .kind = .fabric_output, .arity = 3, .fabric = true },
            .{ .name = "texel_content", .kind = .fabric_content, .arity = 2, .fabric = true },
            .{ .name = "texel_evaluator", .kind = .fabric_evaluator, .arity = 2, .fabric = true },
            .{ .name = "texel_set", .kind = .fabric_set, .arity = 3, .fabric = true },
        };
        const matched = for (builtins) |builtin| {
            if (std.mem.eql(u8, call.callee, builtin.name)) break builtin;
        } else return .not_builtin;

        if (matched.host and !self.analyzer.options.allow_host) {
            try self.fail(
                "luce.sema.host",
                call.span,
                "{s} is a host builtin; this host does not allow console, file, or terminal access here",
                .{matched.name},
            );
            return .failed;
        }
        if (matched.fabric and !self.analyzer.options.allow_fabric) {
            try self.fail(
                "luce.sema.fabric",
                call.span,
                "{s} is a fabric builtin; this host does not allow fabric intents here",
                .{matched.name},
            );
            return .failed;
        }
        if (call.arguments.len != matched.arity) {
            try self.fail("luce.sema.call", call.span, "{s} takes {d} arguments", .{ matched.name, matched.arity });
            return .failed;
        }
        var argument_expressions: [3]*ast.Expression = undefined;
        for (call.arguments, 0..) |argument, index| {
            if (argument.name != null) {
                try self.fail("luce.sema.call", argument.span, "builtin arguments are positional", .{});
                return .failed;
            }
            argument_expressions[index] = argument.value;
        }
        const arguments = (try self.lowerOperands(argument_expressions[0..call.arguments.len])) orelse
            return .failed;

        // Argument and result typing per builtin.
        var result: Type = .none;
        switch (matched.kind) {
            .abs => {
                if (!arguments[0].value_type.isNumeric()) return self.intrinsicType(call, "abs takes Int or Float");
                result = arguments[0].value_type;
            },
            .min, .max => {
                if (!arguments[0].value_type.isNumeric() or
                    !arguments[0].value_type.eql(arguments[1].value_type))
                    return self.intrinsicType(call, "min/max take two Ints or two Floats");
                result = arguments[0].value_type;
            },
            .clamp => {
                if (!arguments[0].value_type.isNumeric() or
                    !arguments[0].value_type.eql(arguments[1].value_type) or
                    !arguments[0].value_type.eql(arguments[2].value_type))
                    return self.intrinsicType(call, "clamp takes three Ints or three Floats");
                result = arguments[0].value_type;
            },
            .sqrt, .floor, .ceil => {
                if (arguments[0].value_type != .float)
                    return self.intrinsicType(call, "this builtin takes a Float");
                result = .float;
            },
            .len => {
                const measurable = arguments[0].value_type == .string or
                    arguments[0].value_type == .bytes or
                    arguments[0].value_type == .heap;
                if (!measurable)
                    return self.intrinsicType(call, "len takes a String, Bytes, List, Map, Array, or Builder");
                result = .int;
            },
            .free_object => {
                if (arguments[0].value_type != .heap)
                    return self.intrinsicType(call, "free releases a List, Map, Array, or Builder");
                // free is deliberate early release of an owned name,
                // and poisons the name like give does (S6).
                const operand = call.arguments[0].value;
                if (operand.* != .name) {
                    try self.fail(
                        "luce.sema.own",
                        call.span,
                        "free releases an owned name; containers free their own elements [OWNERSHIP.md S6, S22]",
                        .{},
                    );
                    return .failed;
                }
                const found = self.findLocal(operand.name.text).?;
                switch (found.info.class) {
                    .borrow_param => {
                        try self.fail(
                            "luce.sema.own",
                            call.span,
                            "{s} is a borrowed parameter and cannot be freed; only owners free [OWNERSHIP.md S12]",
                            .{operand.name.text},
                        );
                        return .failed;
                    },
                    .alias => {
                        try self.fail(
                            "luce.sema.own",
                            call.span,
                            "{s} aliases an object it does not own; free the owning name [OWNERSHIP.md S6, S8]",
                            .{operand.name.text},
                        );
                        return .failed;
                    },
                    .owned => {},
                }
                if (self.loops.items.len > 0 and
                    found.depth < self.loops.items[self.loops.items.len - 1].scope_depth)
                {
                    try self.fail(
                        "luce.sema.own",
                        call.span,
                        "{s} is declared outside this loop; the next iteration would use a freed name [OWNERSHIP.md S30]",
                        .{operand.name.text},
                    );
                    return .failed;
                }
                found.info.poisoned = .freed;
                result = .none;
            },
            .str_value => {
                const descriptor = self.analyzer.heapOf(arguments[0].value_type);
                const stringable = switch (arguments[0].value_type) {
                    .int, .float, .boolean, .string => true,
                    .heap => descriptor.? == .builder,
                    else => false,
                };
                if (!stringable)
                    return self.intrinsicType(call, "str takes Int, Float, Bool, String, or Builder");
                result = .string;
            },
            .parse_int, .parse_float => {
                if (arguments[0].value_type != .string)
                    return self.intrinsicType(call, "this builtin parses a String");
                result = if (matched.kind == .parse_int) .int else .float;
            },
            .chr_code => {
                if (arguments[0].value_type != .int)
                    return self.intrinsicType(call, "chr takes an Int codepoint");
                result = .string;
            },
            .ord_text => {
                if (arguments[0].value_type != .string)
                    return self.intrinsicType(call, "ord takes a String");
                result = .int;
            },
            // Lowered from syntax or method calls, never from bare names.
            .give_object,
            .copy_object,
            .null_object,
            .index_get,
            .index_set,
            .list_slice,
            .key_at,
            .string_slice,
            .string_byte,
            .append_value,
            .pop_value,
            .insert_value,
            .remove_entry,
            .has_key,
            .dim_size,
            .str_find,
            .str_contains,
            .str_starts,
            .str_ends,
            .str_trim,
            .str_lower,
            .str_upper,
            .str_replace,
            .str_repeat,
            .str_split,
            .list_sort,
            .list_reverse,
            .list_find,
            .list_contains,
            .list_join,
            .clear_object,
            .map_keys,
            .array_fill,
            => unreachable,

            .assert_true => {
                if (arguments[0].value_type != .boolean)
                    return self.intrinsicType(call, "assert takes a Bool");
                result = .none;
            },
            .trap_message => {
                if (arguments[0].value_type != .string)
                    return self.intrinsicType(call, "trap takes a String message");
                result = .none;
            },
            .print, .term_write => {
                if (arguments[0].value_type != .string)
                    return self.intrinsicType(call, "this builtin takes a String");
                result = .none;
            },
            .file_read => {
                if (arguments[0].value_type != .string)
                    return self.intrinsicType(call, "file_read takes a String path");
                result = .string;
            },
            .file_write => {
                if (arguments[0].value_type != .string or arguments[1].value_type != .string)
                    return self.intrinsicType(call, "file_write takes (path String, content String)");
                result = .boolean;
            },
            .file_exists => {
                if (arguments[0].value_type != .string)
                    return self.intrinsicType(call, "file_exists takes a String path");
                result = .boolean;
            },
            .arg_count, .term_rows, .term_cols => {
                result = .int;
            },
            .arg_get => {
                if (arguments[0].value_type != .int)
                    return self.intrinsicType(call, "arg takes an Int index");
                result = .string;
            },
            .term_clear, .term_flush => {
                result = .none;
            },
            .term_move => {
                if (arguments[0].value_type != .int or arguments[1].value_type != .int)
                    return self.intrinsicType(call, "term_move takes (row Int, col Int)");
                result = .none;
            },
            .term_style => {
                if (arguments[0].value_type != .int or
                    arguments[1].value_type != .int or
                    arguments[2].value_type != .boolean)
                    return self.intrinsicType(call, "term_style takes (foreground Int, background Int, bold Bool)");
                result = .none;
            },
            .key_read, .key_text => {
                result = .string;
            },
            .fabric_image => {
                if (arguments[0].value_type != .string or arguments[1].value_type != .int)
                    return self.intrinsicType(call, "create_image takes (path String, pages Int)");
                result = .none;
            },
            .fabric_create => {
                if (arguments[0].value_type != .string)
                    return self.intrinsicType(call, "create_texel takes a String name");
                result = .int;
            },
            .fabric_input, .fabric_output => {
                if (arguments[0].value_type != .int or
                    arguments[1].value_type != .string or
                    arguments[2].value_type != .string)
                    return self.intrinsicType(call, "takes (handle Int, name String, type String)");
                result = .none;
            },
            .fabric_content, .fabric_evaluator => {
                if (arguments[0].value_type != .int or arguments[1].value_type != .string)
                    return self.intrinsicType(call, "takes (handle Int, text String)");
                result = .none;
            },
            .fabric_set => {
                const settable = switch (arguments[2].value_type) {
                    .boolean, .int, .float, .string => true,
                    else => false,
                };
                if (arguments[0].value_type != .int or
                    arguments[1].value_type != .string or !settable)
                    return self.intrinsicType(call, "takes (handle Int, output String, value Bool/Int/Float/String)");
                result = .none;
            },
        }
        if (result == .none and !as_statement) {
            try self.fail("luce.sema.call", call.span, "{s} returns nothing", .{matched.name});
            return .failed;
        }

        const registers = try self.arena().alloc(Register, arguments.len);
        for (arguments, registers) |value, *register| register.* = value.register;
        return .{ .value = .{
            .register = try self.emit(.{ .intrinsic = .{ .kind = matched.kind, .arguments = registers } }, result),
            .value_type = result,
        } };
    }

    fn intrinsicType(self: *FunctionBuilder, call: anytype, message: []const u8) Error!IntrinsicResult {
        try self.fail("luce.sema.type", call.span, "{s}", .{message});
        return .failed;
    }
};
