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

/// Check the tree against the schema and lower it to IR.  Returns null
/// when errors were reported; the diagnostics tell the story.
pub fn analyze(
    arena: Allocator,
    temporary: Allocator,
    tree: *const ast.Program,
    schema: PortSchema,
    options: types.CompileOptions,
    diagnostics: *Diagnostics,
) Error!?Analyzed {
    var analyzer: Analyzer = .{
        .arena = arena,
        .temporary = temporary,
        .tree = tree,
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
    parameter_types: []Type,
    return_type: Type,
    is_entry: bool,
};

const LocalInfo = struct {
    local: LocalId,
    mutable: bool,
};

const Scope = std.StringHashMapUnmanaged(LocalInfo);

const LoopFrame = struct {
    continue_block: BlockId,
    exit_block: BlockId,
};

const Analyzer = struct {
    arena: Allocator,
    temporary: Allocator,
    tree: *const ast.Program,
    schema: PortSchema,
    options: types.CompileOptions,
    diagnostics: *Diagnostics,

    structs: std.ArrayList(StructLayout) = .empty,
    heap_types: std.ArrayList(types.HeapType) = .empty,
    struct_names: std.StringHashMapUnmanaged(u32) = .empty,
    functions: std.ArrayList(FunctionInfo) = .empty,
    function_names: std.StringHashMapUnmanaged(u32) = .empty,
    constants: std.ArrayList([]const u8) = .empty,
    reads: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn deinitScratch(self: *Analyzer) void {
        self.struct_names.deinit(self.temporary);
        self.function_names.deinit(self.temporary);
        self.reads.deinit(self.temporary);
    }

    fn fail(self: *Analyzer, code: []const u8, span: Span, comptime format: []const u8, arguments: anytype) Error!void {
        try self.diagnostics.add(code, span, format, arguments);
    }

    fn run(self: *Analyzer) Error!?Analyzed {
        try self.collectStructs();
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

    fn resolveType(self: *Analyzer, written: ast.TypeName) Error!?Type {
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
            const element = (try self.resolveType(written.arguments[0])) orelse return null;
            return try self.internHeapType(.{ .list = element });
        }
        if (std.mem.eql(u8, written.name, "Map")) {
            if (written.arguments.len != 2 or written.wildcards != 0) {
                try self.fail("luce.sema.type", written.span, "Map takes key and value types: Map(String, Int)", .{});
                return null;
            }
            const key = (try self.resolveType(written.arguments[0])) orelse return null;
            if (key != .int and key != .string) {
                try self.fail("luce.sema.type", written.arguments[0].span, "Map keys are Int or String", .{});
                return null;
            }
            const value = (try self.resolveType(written.arguments[1])) orelse return null;
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
            const element = (try self.resolveType(written.arguments[0])) orelse return null;
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
        if (self.struct_names.get(written.name)) |index| return .{ .strukt = index };
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

    fn collectStructs(self: *Analyzer) Error!void {
        // Names first so fields may reference structs in any order.
        for (self.tree.structs) |declaration| {
            if (isReserved(declaration.name)) {
                try self.fail("luce.sema.reserved", declaration.span, "{s} is a reserved name", .{declaration.name});
                continue;
            }
            if (self.struct_names.contains(declaration.name)) {
                try self.fail("luce.sema.duplicate", declaration.span, "duplicate struct {s}", .{declaration.name});
                continue;
            }
            const index: u32 = @intCast(self.structs.items.len);
            try self.struct_names.put(self.temporary, declaration.name, index);
            try self.structs.append(self.arena, .{
                .name = try self.arena.dupe(u8, declaration.name),
                .fields = &.{},
            });
        }

        for (self.tree.structs) |declaration| {
            const index = self.struct_names.get(declaration.name) orelse continue;
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
                const field_type = (try self.resolveType(field.type_name)) orelse continue;
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
                try self.fail(
                    "luce.sema.struct",
                    self.tree.structs[index].span,
                    "struct {s} contains itself",
                    .{self.structs.items[index].name},
                );
            }
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
        for (self.tree.functions) |*declaration| {
            try self.collectFunction(declaration, declaration.name, true);
        }
        for (self.tree.structs) |*declaration| {
            for (declaration.functions) |*function| {
                const qualified = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{
                    declaration.name,
                    function.name,
                });
                try self.collectFunction(function, qualified, false);
            }
        }
        try self.checkEntry();
    }

    fn collectFunction(
        self: *Analyzer,
        declaration: *const ast.FuncDecl,
        name: []const u8,
        top_level: bool,
    ) Error!void {
        if (isReserved(declaration.name) and
            !(top_level and std.mem.eql(u8, declaration.name, "evaluate")))
        {
            try self.fail("luce.sema.reserved", declaration.span, "{s} is a reserved name", .{declaration.name});
            return;
        }
        if (self.function_names.contains(name) or
            (top_level and self.struct_names.contains(name)))
        {
            try self.fail("luce.sema.duplicate", declaration.span, "duplicate name {s}", .{name});
            return;
        }

        const entry_name = if (self.options.entry_mode == .evaluator) "evaluate" else "main";
        const is_entry = top_level and std.mem.eql(u8, declaration.name, entry_name);
        var parameter_types: std.ArrayList(Type) = .empty;
        defer parameter_types.deinit(self.arena);
        if (!is_entry) {
            for (declaration.parameters) |parameter| {
                const resolved = (try self.resolveType(parameter.type_name)) orelse continue;
                try parameter_types.append(self.arena, resolved);
            }
        }
        var return_type: Type = .none;
        if (declaration.return_type) |written| {
            return_type = (try self.resolveType(written)) orelse .none;
        }

        const index: u32 = @intCast(self.functions.items.len);
        try self.function_names.put(self.temporary, name, index);
        try self.functions.append(self.arena, .{
            .declaration = declaration,
            .name = try self.arena.dupe(u8, name),
            .parameter_types = try parameter_types.toOwnedSlice(self.arena),
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
        var builder: FunctionBuilder = .{
            .analyzer = self,
            .return_type = info.return_type,
            .has_frames = info.is_entry and self.options.entry_mode == .evaluator,
        };
        defer builder.deinitScratch();

        try builder.openBlock();
        try builder.pushScope();

        if (!info.is_entry) {
            for (info.declaration.parameters, 0..) |parameter, index| {
                if (index >= info.parameter_types.len) break;
                _ = try builder.declareLocal(
                    parameter.name,
                    info.parameter_types[index],
                    false,
                    parameter.span,
                );
            }
        }

        try builder.lowerBlock(info.declaration.body);
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
    return_type: Type,
    has_frames: bool,
    locals: std.ArrayList(ir.Local) = .empty,
    instructions: std.ArrayList(ir.Instruction) = .empty,
    result_types: std.ArrayList(Type) = .empty,
    blocks: std.ArrayList(BlockBuilder) = .empty,
    current: BlockId = 0,
    scopes: std.ArrayList(Scope) = .empty,
    loops: std.ArrayList(LoopFrame) = .empty,

    fn arena(self: *FunctionBuilder) Allocator {
        return self.analyzer.arena;
    }

    fn temporary(self: *FunctionBuilder) Allocator {
        return self.analyzer.temporary;
    }

    fn deinitScratch(self: *FunctionBuilder) void {
        for (self.scopes.items) |*scope| scope.deinit(self.temporary());
        self.scopes.deinit(self.temporary());
        self.loops.deinit(self.temporary());
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
        scope.deinit(self.temporary());
    }

    fn findLocal(self: *const FunctionBuilder, name: []const u8) ?LocalInfo {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            if (self.scopes.items[index].get(name)) |found| return found;
        }
        return null;
    }

    fn declareLocal(self: *FunctionBuilder, name: []const u8, local_type: Type, mutable: bool, span: Span) Error!?LocalId {
        if (isReserved(name) or std.mem.eql(u8, name, "evaluate")) {
            try self.fail("luce.sema.reserved", span, "{s} is a reserved name", .{name});
            return null;
        }
        if (self.findLocal(name) != null) {
            try self.fail("luce.sema.duplicate", span, "{s} is already declared", .{name});
            return null;
        }
        if (self.analyzer.function_names.contains(name) or
            self.analyzer.struct_names.contains(name))
        {
            try self.fail("luce.sema.duplicate", span, "{s} is already a declaration", .{name});
            return null;
        }
        const local: LocalId = @intCast(self.locals.items.len);
        try self.locals.append(self.arena(), .{
            .name = try self.arena().dupe(u8, name),
            .local_type = local_type,
        });
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.put(self.temporary(), name, .{ .local = local, .mutable = mutable });
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

    // Statements -----------------------------------------------------------

    fn lowerBlock(self: *FunctionBuilder, block: ast.Block) Error!void {
        try self.pushScope();
        for (block.statements) |statement| {
            try self.lowerStatement(statement);
        }
        self.popScope();
    }

    fn lowerStatement(self: *FunctionBuilder, statement: ast.Statement) Error!void {
        switch (statement) {
            .let => |binding| try self.lowerBinding(binding.name, binding.annotation, binding.value, false, binding.span),
            .variable => |binding| try self.lowerBinding(binding.name, binding.annotation, binding.value, true, binding.span),
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
                _ = try self.emit(.{ .jump = frame.exit_block }, .none);
            },
            .continue_statement => |continued| {
                if (self.loops.items.len == 0) {
                    try self.fail("luce.sema.loop", continued.span, "continue outside a loop", .{});
                    return;
                }
                const frame = self.loops.items[self.loops.items.len - 1];
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
            const expected = (try self.analyzer.resolveType(written)) orelse return;
            const descriptor = self.analyzer.heapOf(expected);
            if (descriptor == null or descriptor.? != .list) {
                try self.fail("luce.sema.type", span, "[] builds a List, but {s} is annotated {s}", .{
                    name,
                    try self.analyzer.typeName(expected),
                });
                return;
            }
            const list = try self.emit(.{ .heap_new = .{ .heap = expected.heap, .dims = &.{} } }, expected);
            const local = (try self.declareLocal(name, expected, mutable, span)) orelse return;
            _ = try self.emit(.{ .local_set = .{ .local = local, .value = list } }, .none);
            return;
        }

        const value = (try self.lowerExpression(value_expression, false)) orelse return;
        if (annotation) |written| {
            const expected = (try self.analyzer.resolveType(written)) orelse return;
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
        const local = (try self.declareLocal(name, value.value_type, mutable, span)) orelse return;
        _ = try self.emit(.{ .local_set = .{ .local = local, .value = value.register } }, .none);
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
            try self.fail("luce.sema.name", span, "unknown name {s}", .{base});
            return;
        };
        if (!found.mutable) {
            try self.fail("luce.sema.let", span, "{s} is let-bound; use var for reassignment", .{base});
            return;
        }
        const local_type = self.locals.items[found.local].local_type;
        const value = (try self.lowerExpression(assign.value, false)) orelse return;
        if (!value.value_type.eql(local_type)) {
            try self.fail("luce.sema.type", assign.span, "{s} is {s} but the value is {s}", .{
                base,
                try self.analyzer.typeName(local_type),
                try self.analyzer.typeName(value.value_type),
            });
            return;
        }
        _ = try self.emit(.{ .local_set = .{ .local = found.local, .value = value.register } }, .none);
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
        if (!found.mutable) {
            try self.fail("luce.sema.let", target.span, "{s} is let-bound; use var for reassignment", .{target.base});
            return;
        }
        const local_type = self.locals.items[found.local].local_type;
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
        const current = try self.emit(.{ .local_get = found.local }, local_type);
        const updated = try self.emit(.{ .struct_set = .{
            .target = current,
            .layout = layout_index,
            .field = field_index,
            .value = value.register,
        } }, local_type);
        _ = try self.emit(.{ .local_set = .{ .local = found.local, .value = updated } }, .none);
    }

    /// place[i] = v, grid[r, c] = v, m[key] = v.  The base may be any
    /// expression: objects mutate through the reference, so no local
    /// write-back is needed.
    fn lowerAssignIndex(self: *FunctionBuilder, target: anytype, assign: anytype) Error!void {
        const object = (try self.lowerExpression(target.base, false)) orelse return;
        const element = (try self.checkIndex(object, target.indices, target.span)) orelse return;
        const value = (try self.lowerExpression(assign.value, false)) orelse return;
        if (!value.value_type.eql(element.element_type)) {
            try self.fail("luce.sema.type", assign.span, "this place holds {s} but the value is {s}", .{
                try self.analyzer.typeName(element.element_type),
                try self.analyzer.typeName(value.value_type),
            });
            return;
        }
        const arguments = try self.arena().alloc(Register, 2 + element.indices.len);
        arguments[0] = object.register;
        @memcpy(arguments[1 .. 1 + element.indices.len], element.indices);
        arguments[arguments.len - 1] = value.register;
        _ = try self.emit(.{ .intrinsic = .{ .kind = .index_set, .arguments = arguments } }, .none);
    }

    const IndexCheck = struct {
        element_type: Type,
        indices: []Register,
    };

    /// Type-check an index list against a heap object: lists take one
    /// Int, arrays take rank Ints, maps take one key.  Returns the
    /// element/value type and the lowered index registers.
    fn checkIndex(
        self: *FunctionBuilder,
        object: Value,
        indices: []*ast.Expression,
        span: Span,
    ) Error!?IndexCheck {
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

        const registers = try self.arena().alloc(Register, indices.len);
        var lowered: [4]Value = undefined;
        if (indices.len > 4) {
            try self.fail("luce.sema.index", span, "at most 4 index dimensions", .{});
            return null;
        }
        for (indices, 0..) |expression, at| {
            lowered[at] = (try self.lowerExpression(expression, false)) orelse return null;
            registers[at] = lowered[at].register;
        }

        switch (descriptor) {
            .list => |element| {
                if (indices.len != 1 or lowered[0].value_type != .int) {
                    try self.fail("luce.sema.index", span, "lists index with one Int", .{});
                    return null;
                }
                return .{ .element_type = element, .indices = registers };
            },
            .array => |shape| {
                if (indices.len != shape.rank) {
                    try self.fail("luce.sema.index", span, "this array has {d} dimensions, got {d} indices", .{
                        shape.rank,
                        indices.len,
                    });
                    return null;
                }
                for (lowered[0..indices.len]) |index_value| {
                    if (index_value.value_type != .int) {
                        try self.fail("luce.sema.index", span, "array indices are Int", .{});
                        return null;
                    }
                }
                return .{ .element_type = shape.element, .indices = registers };
            },
            .map => |pair| {
                if (indices.len != 1 or !lowered[0].value_type.eql(pair.key)) {
                    try self.fail("luce.sema.index", span, "this map is keyed by {s}", .{
                        try self.analyzer.typeName(pair.key),
                    });
                    return null;
                }
                return .{ .element_type = pair.value, .indices = registers };
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
        const condition = (try self.lowerCondition(conditional.condition)) orelse return;
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
        const condition = (try self.lowerCondition(loop.condition)) orelse {
            _ = try self.emit(.{ .jump = exit }, .none);
            self.switchTo(exit);
            return;
        };
        _ = try self.emit(.{ .branch = .{
            .condition = condition.register,
            .then_block = body,
            .else_block = exit,
        } }, .none);

        self.switchTo(body);
        try self.loops.append(self.temporary(), .{ .continue_block = header, .exit_block = exit });
        try self.lowerBlock(loop.body);
        _ = self.loops.pop();
        _ = try self.emit(.{ .jump = header }, .none);

        self.switchTo(exit);
    }

    fn lowerForRange(self: *FunctionBuilder, loop: anytype) Error!void {
        const start = (try self.lowerExpression(loop.start, false)) orelse return;
        const end = (try self.lowerExpression(loop.end, false)) orelse return;
        if (start.value_type != .int or end.value_type != .int) {
            try self.fail("luce.sema.type", loop.span, "range bounds must be Int", .{});
            return;
        }

        try self.pushScope();
        defer self.popScope();
        const index_local = (try self.declareLocal(loop.name, .int, false, loop.span)) orelse return;
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
        try self.loops.append(self.temporary(), .{ .continue_block = step, .exit_block = exit });
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
        const name_local = (try self.declareLocal(loop.name, element_type, false, loop.span)) orelse return;
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
        try self.loops.append(self.temporary(), .{ .continue_block = step, .exit_block = exit });
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
            _ = try self.emit(.{ .ret = value.register }, .none);
            return;
        }
        if (self.return_type != .none) {
            try self.fail("luce.sema.return", returned.span, "return needs a {s} value", .{
                try self.analyzer.typeName(self.return_type),
            });
            return;
        }
        _ = try self.emit(.{ .ret = null }, .none);
    }

    // Expressions ----------------------------------------------------------

    fn lowerExpression(self: *FunctionBuilder, expression: *ast.Expression, as_statement: bool) Error!?Value {
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
                    try self.fail("luce.sema.name", name.span, "unknown name {s}", .{name.text});
                    return null;
                };
                const local_type = self.locals.items[found.local].local_type;
                return .{ .register = try self.emit(.{ .local_get = found.local }, local_type), .value_type = local_type };
            },
            .field => |field| return self.lowerField(field),
            .call => |call| return self.lowerCall(call, as_statement),
            .binary => |binary| return self.lowerBinary(binary),
            .unary => |unary| return self.lowerUnary(unary),
            .new_object => |new| return self.lowerNew(new),
            .list_literal => |literal| return self.lowerListLiteral(literal),
            .index => |index| return self.lowerIndex(index),
            .slice_range => |slice| return self.lowerSliceRange(slice),
        }
    }

    fn lowerNew(self: *FunctionBuilder, new: anytype) Error!?Value {
        var object_type: Type = undefined;
        var dims: []Register = &.{};
        if (std.mem.eql(u8, new.type_name.name, "Array")) {
            if (new.dims.len == 0 or new.dims.len > 4) {
                try self.fail("luce.sema.new", new.span, "new Array takes 1 to 4 dimension sizes: new Array(Int, 5, 5)", .{});
                return null;
            }
            const element = (try self.analyzer.resolveType(new.type_name.arguments[0])) orelse return null;
            object_type = try self.analyzer.internHeapType(.{
                .array = .{ .element = element, .rank = @intCast(new.dims.len) },
            });
            dims = try self.arena().alloc(Register, new.dims.len);
            for (new.dims, dims) |expression, *register| {
                const dimension = (try self.lowerExpression(expression, false)) orelse return null;
                if (dimension.value_type != .int) {
                    try self.fail("luce.sema.new", expression.span(), "array dimensions are Int", .{});
                    return null;
                }
                register.* = dimension.register;
            }
        } else {
            object_type = (try self.analyzer.resolveType(new.type_name)) orelse return null;
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
        var elements: std.ArrayList(Value) = .empty;
        defer elements.deinit(self.temporary());
        for (literal.elements) |expression| {
            const element = (try self.lowerExpression(expression, false)) orelse return null;
            if (elements.items.len > 0 and !element.value_type.eql(elements.items[0].value_type)) {
                try self.fail("luce.sema.type", expression.span(), "list elements are all {s}, got {s}", .{
                    try self.analyzer.typeName(elements.items[0].value_type),
                    try self.analyzer.typeName(element.value_type),
                });
                return null;
            }
            try elements.append(self.temporary(), element);
        }
        const object_type = try self.analyzer.internHeapType(.{ .list = elements.items[0].value_type });
        const list = try self.emit(.{ .heap_new = .{ .heap = object_type.heap, .dims = &.{} } }, object_type);
        for (elements.items) |element| {
            const arguments = try self.arena().alloc(Register, 2);
            arguments[0] = list;
            arguments[1] = element.register;
            _ = try self.emit(.{ .intrinsic = .{ .kind = .append_value, .arguments = arguments } }, .none);
        }
        return .{ .register = list, .value_type = object_type };
    }

    fn lowerIndex(self: *FunctionBuilder, index: anytype) Error!?Value {
        const object = (try self.lowerExpression(index.target, false)) orelse return null;
        const element = (try self.checkIndex(object, index.indices, index.span)) orelse return null;
        const arguments = try self.arena().alloc(Register, 1 + element.indices.len);
        arguments[0] = object.register;
        @memcpy(arguments[1..], element.indices);
        return .{
            .register = try self.emit(
                .{ .intrinsic = .{ .kind = .index_get, .arguments = arguments } },
                element.element_type,
            ),
            .value_type = element.element_type,
        };
    }

    fn lowerSliceRange(self: *FunctionBuilder, slice: anytype) Error!?Value {
        const target = (try self.lowerExpression(slice.target, false)) orelse return null;
        const is_string = target.value_type == .string;
        const descriptor = self.analyzer.heapOf(target.value_type);
        if (!is_string and (descriptor == null or descriptor.? != .list)) {
            try self.fail("luce.sema.index", slice.span, "{s} cannot be sliced; slices work on List and String", .{
                try self.analyzer.typeName(target.value_type),
            });
            return null;
        }

        var start: Register = undefined;
        if (slice.start) |expression| {
            const value = (try self.lowerExpression(expression, false)) orelse return null;
            if (value.value_type != .int) {
                try self.fail("luce.sema.type", expression.span(), "slice bounds are Int", .{});
                return null;
            }
            start = value.register;
        } else {
            start = try self.emit(.{ .const_int = 0 }, .int);
        }
        var end: Register = undefined;
        if (slice.end) |expression| {
            const value = (try self.lowerExpression(expression, false)) orelse return null;
            if (value.value_type != .int) {
                try self.fail("luce.sema.type", expression.span(), "slice bounds are Int", .{});
                return null;
            }
            end = value.register;
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
        const left = (try self.lowerExpression(binary.left, false)) orelse return null;
        const right = (try self.lowerExpression(binary.right, false)) orelse return null;
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
        if (self.analyzer.struct_names.get(call.callee)) |layout_index| {
            return self.lowerConstruct(call, layout_index);
        }
        if (std.mem.eql(u8, call.callee, "Int") or std.mem.eql(u8, call.callee, "Float")) {
            return self.lowerConvert(call);
        }
        switch (try self.lowerIntrinsic(call, as_statement)) {
            .not_builtin => {},
            .failed => return null,
            .value => |value| return value,
        }

        const function_index = self.analyzer.function_names.get(call.callee) orelse {
            try self.fail("luce.sema.call", call.span, "unknown function {s}", .{call.callee});
            return null;
        };
        const info = self.analyzer.functions.items[function_index];
        if (info.is_entry) {
            try self.fail("luce.sema.call", call.span, "entry function {s} cannot be called", .{call.callee});
            return null;
        }
        if (call.arguments.len != info.parameter_types.len) {
            try self.fail("luce.sema.call", call.span, "{s} takes {d} arguments, got {d}", .{
                call.callee,
                info.parameter_types.len,
                call.arguments.len,
            });
            return null;
        }
        const registers = try self.arena().alloc(Register, call.arguments.len);
        for (call.arguments, 0..) |argument, index| {
            if (argument.name != null) {
                try self.fail("luce.sema.call", argument.span, "function arguments are positional", .{});
                return null;
            }
            const value = (try self.lowerExpression(argument.value, false)) orelse return null;
            if (!value.value_type.eql(info.parameter_types[index])) {
                try self.fail("luce.sema.type", argument.span, "argument {d} of {s} is {s}, got {s}", .{
                    index + 1,
                    call.callee,
                    try self.analyzer.typeName(info.parameter_types[index]),
                    try self.analyzer.typeName(value.value_type),
                });
                return null;
            }
            registers[index] = value.register;
        }
        if (info.return_type == .none and !as_statement) {
            try self.fail("luce.sema.call", call.span, "{s} returns nothing", .{call.callee});
            return null;
        }
        return .{
            .register = try self.emit(.{ .call = .{ .function = function_index, .arguments = registers } }, info.return_type),
            .value_type = info.return_type,
        };
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

        for (call.arguments) |argument| {
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
            const value = (try self.lowerExpression(argument.value, false)) orelse return null;
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
            .{ .name = "slice", .kind = .string_slice, .arity = 3 },
            .{ .name = "byte_at", .kind = .string_byte, .arity = 2 },
            .{ .name = "assert", .kind = .assert_true, .arity = 1 },
            .{ .name = "trap", .kind = .trap_message, .arity = 1 },
            .{ .name = "append", .kind = .append_value, .arity = 2 },
            .{ .name = "pop", .kind = .pop_value, .arity = 1 },
            .{ .name = "insert", .kind = .insert_value, .arity = 3 },
            .{ .name = "remove", .kind = .remove_entry, .arity = 2 },
            .{ .name = "has", .kind = .has_key, .arity = 2 },
            .{ .name = "dim", .kind = .dim_size, .arity = 2 },
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
        var argument_values: [3]Value = undefined;
        for (call.arguments, 0..) |argument, index| {
            if (argument.name != null) {
                try self.fail("luce.sema.call", argument.span, "builtin arguments are positional", .{});
                return .failed;
            }
            argument_values[index] = (try self.lowerExpression(argument.value, false)) orelse
                return .failed;
        }
        const arguments = argument_values[0..call.arguments.len];

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
            .append_value => {
                const descriptor = self.analyzer.heapOf(arguments[0].value_type) orelse
                    return self.intrinsicType(call, "append takes a List or Builder first");
                switch (descriptor) {
                    .list => |element| {
                        if (!arguments[1].value_type.eql(element))
                            return self.intrinsicType(call, "appended value must match the list's element type");
                    },
                    .builder => {
                        if (arguments[1].value_type != .string)
                            return self.intrinsicType(call, "a Builder appends String");
                    },
                    else => return self.intrinsicType(call, "append takes a List or Builder first"),
                }
                result = .none;
            },
            .pop_value => {
                const descriptor = self.analyzer.heapOf(arguments[0].value_type) orelse
                    return self.intrinsicType(call, "pop takes a List");
                if (descriptor != .list) return self.intrinsicType(call, "pop takes a List");
                result = descriptor.list;
            },
            .insert_value => {
                const descriptor = self.analyzer.heapOf(arguments[0].value_type) orelse
                    return self.intrinsicType(call, "insert takes (List, index Int, value)");
                if (descriptor != .list or arguments[1].value_type != .int or
                    !arguments[2].value_type.eql(descriptor.list))
                    return self.intrinsicType(call, "insert takes (List, index Int, value)");
                result = .none;
            },
            .remove_entry => {
                const descriptor = self.analyzer.heapOf(arguments[0].value_type) orelse
                    return self.intrinsicType(call, "remove takes (List, index) or (Map, key)");
                switch (descriptor) {
                    .list => {
                        if (arguments[1].value_type != .int)
                            return self.intrinsicType(call, "list remove takes an Int index");
                    },
                    .map => |pair| {
                        if (!arguments[1].value_type.eql(pair.key))
                            return self.intrinsicType(call, "map remove takes the map's key type");
                    },
                    else => return self.intrinsicType(call, "remove takes (List, index) or (Map, key)"),
                }
                result = .none;
            },
            .has_key => {
                const descriptor = self.analyzer.heapOf(arguments[0].value_type) orelse
                    return self.intrinsicType(call, "has takes (Map, key)");
                if (descriptor != .map or !arguments[1].value_type.eql(descriptor.map.key))
                    return self.intrinsicType(call, "has takes (Map, key)");
                result = .boolean;
            },
            .dim_size => {
                const descriptor = self.analyzer.heapOf(arguments[0].value_type) orelse
                    return self.intrinsicType(call, "dim takes (Array, axis Int)");
                if (descriptor != .array or arguments[1].value_type != .int)
                    return self.intrinsicType(call, "dim takes (Array, axis Int)");
                result = .int;
            },
            .free_object => {
                if (arguments[0].value_type != .heap)
                    return self.intrinsicType(call, "free releases a List, Map, Array, or Builder");
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
            .index_get, .index_set, .list_slice, .key_at => unreachable, // lowered from syntax, never named
            .string_slice => {
                if (arguments[0].value_type != .string or
                    arguments[1].value_type != .int or
                    arguments[2].value_type != .int)
                    return self.intrinsicType(call, "slice takes (String, start Int, end Int)");
                result = .string;
            },
            .string_byte => {
                if (arguments[0].value_type != .string or arguments[1].value_type != .int)
                    return self.intrinsicType(call, "byte_at takes (String, index Int)");
                result = .int;
            },
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
