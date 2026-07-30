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
    "input",        "output",           "Input",           "Output",       "range",
    "Int",          "Float",            "Bool",            "String",       "Bytes",
    "abs",          "min",              "max",             "clamp",        "sqrt",
    "floor",        "ceil",             "len",             "slice",        "byte_at",
    "assert",       "trap",             "evaluate",        "create_texel", "texel_input",
    "texel_output", "texel_content",    "texel_evaluator", "texel_set",    "create_image",
    "read_file",    "script_directory",
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
            if (std.mem.eql(u8, written.name, entry.name)) return entry.resolved;
        }
        if (self.struct_names.get(written.name)) |index| return .{ .strukt = index };
        try self.fail("luce.sema.type", written.span, "unknown type {s}", .{written.name});
        return null;
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

    fn typeName(self: *const Analyzer, of: Type) []const u8 {
        return types.typeName(self.structs.items, of);
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
        const value = (try self.lowerExpression(value_expression, false)) orelse return;
        if (annotation) |written| {
            const expected = (try self.analyzer.resolveType(written)) orelse return;
            if (!value.value_type.eql(expected)) {
                try self.fail(
                    "luce.sema.type",
                    span,
                    "{s} declared {s} but initialized with {s} (conversions are explicit: {s}(...))",
                    .{ name, self.analyzer.typeName(expected), self.analyzer.typeName(value.value_type), self.analyzer.typeName(expected) },
                );
                return;
            }
        }
        const local = (try self.declareLocal(name, value.value_type, mutable, span)) orelse return;
        _ = try self.emit(.{ .local_set = .{ .local = local, .value = value.register } }, .none);
    }

    fn lowerAssign(self: *FunctionBuilder, assign: anytype) Error!void {
        const target = assign.target;
        if (std.mem.eql(u8, target.base, "output")) {
            if (!self.has_frames) {
                try self.fail("luce.sema.name", target.span, "output exists only in the evaluator entry", .{});
                return;
            }
            const field = target.field orelse {
                try self.fail("luce.sema.output", target.span, "assign to output.NAME", .{});
                return;
            };
            const port = self.analyzer.schema.findOutput(field) orelse {
                try self.fail("luce.sema.port", target.span, "no output port named {s}", .{field});
                return;
            };
            const expected = Type.fromPort(self.analyzer.schema.outputs[port].declared);
            const value = (try self.lowerExpression(assign.value, false)) orelse return;
            if (!value.value_type.eql(expected)) {
                try self.fail("luce.sema.type", assign.span, "output.{s} is {s} but the value is {s}", .{
                    field,
                    self.analyzer.typeName(expected),
                    self.analyzer.typeName(value.value_type),
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

        if (target.field) |field| {
            if (local_type != .strukt) {
                try self.fail("luce.sema.field", target.span, "{s} is {s}, not a struct", .{
                    target.base,
                    self.analyzer.typeName(local_type),
                });
                return;
            }
            const layout_index = local_type.strukt;
            const layout = self.analyzer.structs.items[layout_index];
            const field_index = layout.findField(field) orelse {
                try self.fail("luce.sema.field", target.span, "{s} has no field {s}", .{ layout.name, field });
                return;
            };
            const expected = layout.fields[field_index].field_type;
            const value = (try self.lowerExpression(assign.value, false)) orelse return;
            if (!value.value_type.eql(expected)) {
                try self.fail("luce.sema.type", assign.span, "{s}.{s} is {s} but the value is {s}", .{
                    target.base,
                    field,
                    self.analyzer.typeName(expected),
                    self.analyzer.typeName(value.value_type),
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
            return;
        }

        const value = (try self.lowerExpression(assign.value, false)) orelse return;
        if (!value.value_type.eql(local_type)) {
            try self.fail("luce.sema.type", assign.span, "{s} is {s} but the value is {s}", .{
                target.base,
                self.analyzer.typeName(local_type),
                self.analyzer.typeName(value.value_type),
            });
            return;
        }
        _ = try self.emit(.{ .local_set = .{ .local = found.local, .value = value.register } }, .none);
    }

    fn lowerCondition(self: *FunctionBuilder, expression: *ast.Expression) Error!?Value {
        const condition = (try self.lowerExpression(expression, false)) orelse return null;
        if (condition.value_type != .boolean) {
            try self.fail("luce.sema.type", expression.span(), "condition must be Bool, not {s}", .{
                self.analyzer.typeName(condition.value_type),
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

    fn lowerReturn(self: *FunctionBuilder, returned: anytype) Error!void {
        if (returned.value) |expression| {
            const value = (try self.lowerExpression(expression, false)) orelse return;
            if (self.return_type == .none) {
                try self.fail("luce.sema.return", returned.span, "this function returns nothing", .{});
                return;
            }
            if (!value.value_type.eql(self.return_type)) {
                try self.fail("luce.sema.type", returned.span, "returning {s} from a function returning {s}", .{
                    self.analyzer.typeName(value.value_type),
                    self.analyzer.typeName(self.return_type),
                });
                return;
            }
            _ = try self.emit(.{ .ret = value.register }, .none);
            return;
        }
        if (self.return_type != .none) {
            try self.fail("luce.sema.return", returned.span, "return needs a {s} value", .{
                self.analyzer.typeName(self.return_type),
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
        }
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
                self.analyzer.typeName(target.value_type),
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
                self.analyzer.typeName(left.value_type),
                self.analyzer.typeName(right.value_type),
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
                    self.analyzer.typeName(operand_type),
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
                self.analyzer.typeName(operand_type),
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
                        self.analyzer.typeName(operand.value_type),
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
                    self.analyzer.typeName(info.parameter_types[index]),
                    self.analyzer.typeName(value.value_type),
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
                    self.analyzer.typeName(expected),
                    self.analyzer.typeName(value.value_type),
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
                    self.analyzer.typeName(value.value_type),
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
                self.analyzer.typeName(value.value_type),
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
                if (arguments[0].value_type != .string and arguments[0].value_type != .bytes)
                    return self.intrinsicType(call, "len takes a String or Bytes");
                result = .int;
            },
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
