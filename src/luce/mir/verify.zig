//! IR verifier — structural and type invariant checks.
//! Every piece of code that produces or decodes IR must pass this.

const std = @import("std");
const defs = @import("defs.zig");
const types = @import("../support/types.zig");

const Allocator = std.mem.Allocator;
const Type = types.Type;
const Program = defs.Program;
const Function = defs.Function;
const Instruction = defs.Instruction;
const Register = defs.Register;
const Local = defs.Local;

pub const VerifyError = error{
    OutOfMemory,
    EmptyFunction,
    UnterminatedBlock,
    MisplacedTerminator,
    UndefinedRegister,
    ValuelessRegister,
    TypeMismatch,
    BadLocal,
    BadBlock,
    BadFunction,
    BadStruct,
    BadConstant,
    BadIntrinsic,
    /// `raise_error` or `unwind` in a function that never said it
    /// could fail: a caller compiled against that signature has no
    /// branch to take, so the module is not one this build wrote.
    NotFallible,
};

// ---------------------------------------------------------------------------
// The whole program
// ---------------------------------------------------------------------------

fn traceSiteCountFits(functions: usize, constants: usize) bool {
    const limit: usize = std.math.maxInt(u32);
    return functions <= limit and constants <= limit - functions;
}

/// Check every structural and type invariant of a program.
pub fn verify(allocator: Allocator, program: *const Program) VerifyError!void {
    // Runtime trace frames address real functions first and synthetic
    // constant-declaration sites after them through one u32 index.
    // Each table can fit independently while their concatenation does
    // not, so state the combined wire/runtime invariant before either
    // slice is walked.
    if (!traceSiteCountFits(program.functions.len, program.container_constants.len)) {
        return error.BadConstant;
    }
    // A signature is a type table in its own right.  Check every row,
    // including rows no instruction happens to consume: a decoded
    // module may carry an unused row, and a later type-name or lowering
    // walk is still allowed to read it.
    for (program.signatures) |signature| {
        for (signature.parameters) |parameter| {
            try verifyType(program, parameter.value_type);
        }
        try verifyType(program, signature.result);
    }
    for (program.heap_types) |descriptor| switch (descriptor) {
        // **A bare function type is not an element type**
        // (docs/BINDING.md D7): the storable form is
        // `(func(...) -> R)?`, and a cell has no shape for a function
        // that is always there — which is what `llvm`'s `cellType`,
        // `cellAlignment` and `cellWidth` say with their `unreachable`.
        // Refusing the descriptor here is what makes those arms
        // unreachable rather than merely unreached, so a hand-made or
        // stale module cannot ask the backend for a cell it has no
        // width for.
        .list => |element| {
            if (element == .function) return error.BadStruct;
            try verifyType(program, element);
        },
        // A key is an explicit integer width, `str`, or an enum. An enum
        // reaches the runtime at its backing width (`mir.mapKeyStorage`).
        .map => |pair| {
            if (!pair.key.isInteger() and pair.key != .str and pair.key != .enumeration)
                return error.BadStruct;
            try verifyType(program, pair.key);
            // A map's missing-key answer already supplies the one
            // optional layer (`get` is `V?`).  Stage 4 therefore refuses
            // `map(K, V?)`, including the storable function spelling;
            // keep the decoded-MIR boundary in agreement so `map_get`
            // cannot unwrap a shape with no representable `V??` result.
            if (pair.value == .optional) return error.BadStruct;
            try verifyType(program, pair.value);
        },
        .array => |shape| {
            if (shape.element == .function) return error.BadStruct;
            try verifyType(program, shape.element);
            if (shape.rank < 1 or shape.rank > 4) return error.BadStruct;
        },
        .builder, .file => {},
        .task => |work| try verifyType(program, work.result),
    };
    for (program.structs) |layout| {
        for (layout.fields) |field| try verifyFieldType(program, field.field_type, layout.interface);
    }
    for (program.variants) |declared| {
        // A union with no members has no zero and no tag to dispatch
        // on; stage 4 cannot write one, so this is decode defense.
        if (declared.members.len == 0) return error.BadStruct;
        for (declared.members) |member| {
            for (member.fields) |field| try verifyFieldType(program, field.field_type, false);
        }
    }
    if (try typeTableCycle(allocator, program)) |cycle| return switch (cycle) {
        .heap => error.BadStruct,
        .function => error.BadFunction,
    };
    if (try anyStructContainsItself(allocator, program)) return error.BadStruct;
    // Pool rows are declarations, not merely instruction operands.
    // Verify every one, including rows reachability pruning will later
    // discard, so a decoded module cannot hide damaged constants in an
    // unused slot.
    for (program.container_constants) |constant| {
        try verifyContainerConstant(allocator, program, constant);
    }

    // Every signature is checked before any body is.  A `call` types
    // its arguments against `callee.locals[0..parameter_count]`, and
    // the callee may stand *later* in the table than its caller — so
    // waiting for the callee's own turn would mean indexing a
    // parameter table that has not been bounded yet, and a module
    // claiming more parameters than locals would take the verifier out
    // of bounds instead of being refused.  That module is precisely
    // what `decode` exists to refuse.
    for (program.functions) |*function| {
        if (function.parameter_count > function.locals.len) return error.BadLocal;
        for (function.locals, 0..) |local, index| {
            if (!local.inout) continue;
            if (index != 0 or function.parameter_count == 0) return error.BadLocal;
        }
    }
    for (program.functions) |*function| {
        try verifyFunction(allocator, program, function);
    }
    if (program.entry_function >= program.functions.len) return error.BadFunction;
    const entry = &program.functions[program.entry_function];
    // The entry takes nothing, or it takes the command line and
    // nothing else — the two shapes stage 4 lets through, said again
    // here because a decoded module is not to be trusted about them
    // (MEMORY.md).
    if (entry.parameter_count > 1) return error.BadFunction;
    if (entry.parameter_count != 0 and entry.locals[0].inout) return error.BadFunction;
    if (entry.parameter_count == 1 and !isCommandLine(program, entry.locals[0].local_type)) {
        return error.BadFunction;
    }
}

test "function and constant trace sites share one u32 index" {
    const limit: usize = std.math.maxInt(u32);
    try std.testing.expect(traceSiteCountFits(limit, 0));
    try std.testing.expect(traceSiteCountFits(limit - 4, 4));
    try std.testing.expect(!traceSiteCountFits(limit - 4, 5));
}

/// `list(string)` — the one type the entry's parameter may have.
fn isCommandLine(program: *const Program, of: Type) bool {
    if (of != .heap or of.heap >= program.heap_types.len) return false;
    const descriptor = program.heap_types[of.heap];
    return descriptor == .list and descriptor.list == .str;
}

fn verifyType(program: *const Program, of: Type) VerifyError!void {
    switch (of) {
        .strukt => |index| if (index >= program.structs.len) return error.BadStruct,
        .variant => |index| if (index >= program.variants.len) return error.BadStruct,
        .heap => |index| if (index >= program.heap_types.len) return error.BadStruct,
        .function => |index| if (index >= program.signatures.len) return error.BadFunction,
        // An enum names a row of the enum table, and the width it
        // carries must be the one that row declares: the two are one
        // fact in memory (`types.Type.EnumRef`), and a module that says
        // otherwise would have every engine reading a member at a width
        // the table denies.
        .enumeration => |reference| {
            if (reference.index >= program.enums.len) return error.BadStruct;
            const declared = program.enums[reference.index];
            if (declared.backing != reference.backing) return error.BadStruct;
            if (declared.members.len == 0) return error.BadStruct;
        },
        // A payload is a type in its own right and is bounded the same
        // way; it can never be optional itself, so this is one step.
        .optional => |payload| try verifyType(program, payload.asType()),
        // The scalars index no table, so there is nothing to bound.
        // Listed rather than defaulted because this switch sits on the
        // trust boundary: a type added later that names a row would
        // otherwise pass a crafted `.lcm` straight through `decode`.
        .none,
        .boolean,
        .u8,
        .u16,
        .u32,
        .u64,
        .i8,
        .i16,
        .i32,
        .i64,
        .f16,
        .f32,
        .f64,
        .char,
        .str,
        .bytes,
        => {},
    }
}

/// Source structs cannot declare bare function fields, but compiler-generated
/// interface layouts use them as private dispatch slots. Keep the distinction
/// in the module so a decoded ordinary struct cannot smuggle one through.
fn verifyFieldType(program: *const Program, of: Type, allow_function: bool) VerifyError!void {
    if (of == .function and !allow_function) return error.BadStruct;
    try verifyType(program, of);
}

// ---------------------------------------------------------------------------
// Recursive type tables
// ---------------------------------------------------------------------------

const TypeCycle = enum { heap, function };
const TypeVisit = enum { unvisited, open, closed };

/// Find a cycle among the two tables whose rows render by recursively
/// rendering another row: heap shapes and function signatures.
///
/// Source can only build a finite nesting of these anonymous types,
/// so its interned graph is a DAG.  A decoded module can instead make
/// `func(func(...))`, `list(list(...))`, or a heap/signature cross-cycle.
/// The indices are all in bounds, but `types.typeName` would recurse
/// forever when `luce ir` prints one.  Check every row, including an
/// unused one, with an explicit DFS so hostile depth cannot consume the
/// verifier's call stack.  Structs are leaves here on purpose: a legal
/// `Node` may hold `list(Node)`, and a type name prints the word `Node`
/// rather than expanding its fields.
fn typeTableCycle(allocator: Allocator, program: *const Program) VerifyError!?TypeCycle {
    const heap_count = program.heap_types.len;
    const count = heap_count + program.signatures.len;
    if (count == 0) return null;

    const visits = try allocator.alloc(TypeVisit, count);
    defer allocator.free(visits);
    @memset(visits, .unvisited);

    const Step = struct { node: usize, edge: usize = 0 };
    var path: std.ArrayList(Step) = .empty;
    defer path.deinit(allocator);

    for (0..count) |root| {
        if (visits[root] != .unvisited) continue;
        visits[root] = .open;
        try path.append(allocator, .{ .node = root });

        while (path.items.len != 0) {
            const step = &path.items[path.items.len - 1];
            if (typeReferenceAt(program, step.node, step.edge)) |reference| {
                step.edge += 1;
                const child = typeTableNode(program, reference) orelse continue;
                switch (visits[child]) {
                    .unvisited => {
                        visits[child] = .open;
                        try path.append(allocator, .{ .node = child });
                    },
                    .open => {
                        var kind: TypeCycle = if (child >= heap_count) .function else .heap;
                        var at = path.items.len;
                        while (at > 0) {
                            at -= 1;
                            const member = path.items[at].node;
                            if (member >= heap_count) kind = .function;
                            if (member == child) break;
                        }
                        return kind;
                    },
                    .closed => {},
                }
                continue;
            }

            visits[step.node] = .closed;
            _ = path.pop();
        }
    }
    return null;
}

/// The `edge`th recursively rendered type held by one combined table
/// row, or null after its last edge.
fn typeReferenceAt(program: *const Program, node: usize, edge: usize) ?Type {
    if (node < program.heap_types.len) return switch (program.heap_types[node]) {
        .list => |element| if (edge == 0) element else null,
        .map => |pair| switch (edge) {
            0 => pair.key,
            1 => pair.value,
            else => null,
        },
        .array => |shape| if (edge == 0) shape.element else null,
        .task => |work| if (edge == 0) work.result else null,
        .builder, .file => null,
    };

    const signature = program.signatures[node - program.heap_types.len];
    if (edge < signature.parameters.len) return signature.parameters[edge].value_type;
    if (edge == signature.parameters.len) return signature.result;
    return null;
}

/// The combined-table row a type expands, after peeling the one
/// optional layer the representation permits; null for a printed leaf.
fn typeTableNode(program: *const Program, of: Type) ?usize {
    const expanded = if (of == .optional) of.optional.asType() else of;
    return switch (expanded) {
        .heap => |index| @as(usize, index),
        .function => |index| program.heap_types.len + @as(usize, index),
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Struct layouts, and the one question that can hang a decoder
// ---------------------------------------------------------------------------

/// Does any struct or union contain itself, directly or through
/// another?  Such a layout has no finite value and nothing downstream
/// may assume one exists — a union joins the same graph as a struct
/// because only one member is ever live but every member is counted
/// (docs/UNION.md D12).
///
/// One linear pass over the containment graph — Tarjan's strongly
/// connected components, with an explicit stack.  Asking the question
/// per layout by walking down from it re-walks every *path* through
/// the graph, so a struct with two struct fields doubles the work per
/// level: twenty levels is a million walks, and forty never finishes.
/// Stage 4 refuses cycles before they can reach a `.lcm`, so from
/// source this was already unreachable; a hand-written or fuzzed
/// module reaches it through `decode`, which is exactly the input that
/// must not be able to hang the decoder.  (`semantics/
/// declarations.zig` answers the same question the same way, and also
/// sums each layout's shape while it is there.)
fn anyStructContainsItself(allocator: Allocator, program: *const Program) VerifyError!bool {
    const count = program.structs.len + program.variants.len;
    if (count == 0) return false;

    const unvisited = std.math.maxInt(u32);
    const order = try allocator.alloc(u32, count);
    defer allocator.free(order);
    const lowest = try allocator.alloc(u32, count);
    defer allocator.free(lowest);
    const open = try allocator.alloc(bool, count);
    defer allocator.free(open);
    @memset(order, unvisited);
    @memset(open, false);

    // Tarjan's component stack, and the explicit depth-first one.
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(allocator);
    var path: std.ArrayList(GraphStep) = .empty;
    defer path.deinit(allocator);

    var next_order: u32 = 0;
    for (0..count) |root| {
        if (order[root] != unvisited) continue;
        order[root] = next_order;
        lowest[root] = next_order;
        next_order += 1;
        open[root] = true;
        try pending.append(allocator, @intCast(root));
        try path.append(allocator, .{ .layout = @intCast(root) });

        while (path.items.len != 0) {
            // `step` points into `path`, which the descent below may
            // grow: everything read through it is read before that
            // append, and nothing is read after.
            const step = &path.items[path.items.len - 1];
            const layout = step.layout;
            if (containedLayoutAt(program, step)) |held| {
                // `verifyType` has already bounded every field index.
                if (held == layout) return true;
                if (order[held] == unvisited) {
                    order[held] = next_order;
                    lowest[held] = next_order;
                    next_order += 1;
                    open[held] = true;
                    try pending.append(allocator, held);
                    try path.append(allocator, .{ .layout = held });
                } else if (open[held]) {
                    lowest[layout] = @min(lowest[layout], order[held]);
                }
                continue;
            }

            _ = path.pop();
            if (path.items.len != 0) {
                const parent = path.items[path.items.len - 1].layout;
                lowest[parent] = @min(lowest[parent], lowest[layout]);
            }
            if (lowest[layout] != order[layout]) continue;

            // The root of a component: everything pushed at or after
            // it is a member.  More than one member means they hold
            // each other, so none of them has a finite value.
            var first = pending.items.len;
            while (pending.items[first - 1] != layout) first -= 1;
            first -= 1;
            const members = pending.items[first..];
            if (members.len > 1) return true;
            for (members) |member| open[member] = false;
            pending.shrinkRetainingCapacity(first);
        }
    }
    return false;
}

/// One node of the combined containment graph with the cursor of the
/// depth-first walk over its fields: structs advance `field` alone,
/// variants advance `member` and `field` together, so resuming a scan
/// never re-reads a field it already passed.
const GraphStep = struct { layout: u32, member: u32 = 0, field: u32 = 0 };

/// The next combined containment-graph node one of the step's fields
/// names, advancing the step's cursor past it — skipping fields that
/// hold no layout — or null once the node's fields run out.  Nodes are
/// structs first, then variants at `program.structs.len +`; a
/// variant's fields are its members' payload fields in declaration
/// order, because every member counts for the cycle question
/// (docs/UNION.md D12).
fn containedLayoutAt(program: *const Program, step: *GraphStep) ?u32 {
    if (step.layout < program.structs.len) {
        const fields = program.structs[step.layout].fields;
        while (step.field < fields.len) {
            const held = fields[step.field].field_type;
            step.field += 1;
            if (graphNode(program, held)) |node| return node;
        }
        return null;
    }
    const members = program.variants[step.layout - program.structs.len].members;
    while (step.member < members.len) {
        const fields = members[step.member].fields;
        while (step.field < fields.len) {
            const held = fields[step.field].field_type;
            step.field += 1;
            if (graphNode(program, held)) |node| return node;
        }
        step.member += 1;
        step.field = 0;
    }
    return null;
}

/// The combined-graph node a field type expands into, or null for a
/// type that stops the walk — a container is a handle, and a handle's
/// contents already have an owner and a finite size of their own.
fn graphNode(program: *const Program, of: Type) ?u32 {
    return switch (of) {
        .strukt => |index| index,
        .variant => |index| @intCast(program.structs.len + index),
        else => null,
    };
}

// ---------------------------------------------------------------------------
// One function: its blocks, its registers, its terminators
// ---------------------------------------------------------------------------

fn verifyFunction(
    allocator: Allocator,
    program: *const Program,
    function: *const Function,
) VerifyError!void {
    if (function.blocks.len == 0) return error.EmptyFunction;
    if (function.parameter_count > function.locals.len) return error.BadLocal;
    if (function.instructions.len != function.result_types.len) return error.BadFunction;
    if (function.origins.len != 0 and function.origins.len != function.instructions.len)
        return error.BadFunction;
    try verifyType(program, function.return_type);
    for (function.locals) |local| {
        try verifyType(program, local.local_type);
        // `owns_storage` selects the physical local representation in both
        // engines: a boxed Runtime.Value for storage-bearing values, and
        // the type's direct ABI shape otherwise.  A decoded module must
        // not be able to make those choices disagree with the type graph.
        if (local.owns_storage and !typeCanOwnStorage(local.local_type)) {
            return error.BadLocal;
        }
    }
    for (function.result_types) |result_type| try verifyType(program, result_type);
    for (function.locals[0..function.parameter_count]) |local| {
        // Ordinary parameters borrow value storage from their caller; only
        // a writing receiver, an explicit inout place, may carry a boxed
        // value slot.
        if (!local.inout and local.owns_storage) return error.BadLocal;
    }

    var defined = std.AutoHashMapUnmanaged(Register, void){};
    defer defined.deinit(allocator);
    const seen = try allocator.alloc(bool, function.instructions.len);
    defer allocator.free(seen);
    @memset(seen, false);

    for (function.blocks) |block| {
        if (block.items.len == 0) return error.UnterminatedBlock;
        defined.clearRetainingCapacity();
        for (block.items, 0..) |item, position| {
            if (item >= function.instructions.len) return error.UndefinedRegister;
            if (seen[item]) return error.BadFunction;
            seen[item] = true;
            const instruction = function.instructions[item];
            const last = position == block.items.len - 1;
            if (instruction.isTerminator() != last) {
                return if (last) error.UnterminatedBlock else error.MisplacedTerminator;
            }
            try verifyInstruction(allocator, program, function, &defined, item, instruction);
            try verifyErrorHandling(program, function, block.items, position, item);
            try defined.put(allocator, item, {});
        }
    }
}

fn operandType(function: *const Function, defined: *const std.AutoHashMapUnmanaged(Register, void), register: Register) VerifyError!Type {
    if (register >= function.instructions.len) return error.UndefinedRegister;
    if (!defined.contains(register)) return error.UndefinedRegister;
    const result = function.result_types[register];
    if (result == .none) return error.ValuelessRegister;
    return result;
}

/// Kept as the single seam for serialized modules produced before the
/// explicit-width type system. Every current numeric width computes at
/// its own width, so no current `Type` is storage-only.
fn isStorageWidth(of: Type) bool {
    _ = of;
    return false;
}

/// Whether an integer constant, carried as an `i128`, is exactly what
/// a register of type `at` would hold.
fn fitsInteger(held: i128, at: Type) bool {
    if (!at.isInteger()) return false;
    const bounds = at.integerRange();
    return held >= bounds.low and held <= bounds.high;
}

fn fitsChar(held: i128) bool {
    return held >= 0 and held <= 0x10ffff and !(held >= 0xd800 and held <= 0xdfff);
}

/// The same question for a float constant carried as an `f64`.  A NaN
/// is representable at either width and compares equal to nothing, so
/// it is answered before the round trip rather than by it; an infinity
/// survives the round trip and needs no arm of its own.
fn fitsFloat(held: f64, at: Type) bool {
    return switch (at) {
        .f64 => true,
        .f32 => std.math.isNan(held) or @as(f64, @as(f32, @floatCast(held))) == held,
        .f16 => std.math.isNan(held) or @as(f64, @as(f16, @floatCast(held))) == held,
        .none, .boolean, .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .char, .str, .bytes, .strukt, .heap, .enumeration, .variant, .function, .optional => false,
    };
}

// ---------------------------------------------------------------------------
// Constant-container rows
// ---------------------------------------------------------------------------

/// The source checker bounds the expression that made a value to this
/// depth.  Mirror that limit here so a forged recursive struct value
/// cannot turn verification into native-stack exhaustion.
const max_constant_depth: u32 = 400;

fn verifyContainerConstant(
    allocator: Allocator,
    program: *const Program,
    constant: defs.ContainerConstant,
) VerifyError!void {
    if (constant.name.len == 0) return error.BadConstant;
    const stripped = constant.source.len == 0;
    const zero_origin = constant.origin.line == 0 and constant.origin.column == 0;
    if (stripped) {
        if (!zero_origin) return error.BadConstant;
    } else if (constant.origin.line == 0 or constant.origin.column == 0) {
        return error.BadConstant;
    }

    if (constant.heap >= program.heap_types.len) return error.BadConstant;
    switch (program.heap_types[constant.heap]) {
        .list => |element| switch (constant.payload) {
            .sequence => |values| for (values) |value| {
                try verifyConstantValue(program, value, element, false, 0);
            },
            .map => return error.BadConstant,
        },
        .array => |shape| {
            // Constant arrays are flat rank-one literals.  Their sole
            // dimension is exactly the number of encoded elements;
            // no redundant length exists to disagree with it.
            if (shape.rank != 1) return error.BadConstant;
            switch (constant.payload) {
                .sequence => |values| for (values) |value| {
                    try verifyConstantValue(program, value, shape.element, false, 0);
                },
                .map => return error.BadConstant,
            }
        },
        .map => |pair| switch (constant.payload) {
            .sequence => return error.BadConstant,
            .map => |entries| {
                // `{}` has no source-level type to land on and is
                // deliberately refused in favor of `new map(K, V)`.
                // A forged or stale module must not smuggle that
                // impossible constant shape past the same boundary.
                if (entries.len == 0) return error.BadConstant;
                for (entries) |entry| {
                    try verifyConstantValue(program, entry.key, pair.key, false, 0);
                    try verifyConstantValue(program, entry.value, pair.value, false, 0);
                }
                try verifyDistinctKeys(allocator, program, entries, pair.key);
            },
        },
        .builder, .file, .task => return error.BadConstant,
    }
}

/// A map row preserves written order but may not carry the same key
/// twice.  String identity is its bytes, not the shared-pool index, so
/// two separate slots holding equal text are duplicates too.
///
/// The keys are compared **as they are stored** (`mir.mapKeyStorage`):
/// an enum key is a number, so every integer width shares this path and
/// a duplicated member is the duplicated integer it folds to.
fn verifyDistinctKeys(
    allocator: Allocator,
    program: *const Program,
    entries: []const defs.ContainerConstant.MapEntry,
    key_type: Type,
) VerifyError!void {
    switch (defs.mapKeyStorage(key_type)) {
        .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64 => {
            var seen: std.AutoHashMapUnmanaged(i128, void) = .empty;
            defer seen.deinit(allocator);
            for (entries) |entry| {
                const key = switch (entry.key) {
                    .integer => |value| value,
                    else => unreachable, // verified against the map shape above
                };
                const result = try seen.getOrPut(allocator, key);
                if (result.found_existing) return error.BadConstant;
            }
        },
        .str => {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(allocator);
            for (entries) |entry| {
                const index = switch (entry.key) {
                    .str => |value| value,
                    else => unreachable, // verified against the map shape above
                };
                const bytes = program.constants[index];
                const result = try seen.getOrPut(allocator, bytes);
                if (result.found_existing) return error.BadConstant;
            }
        },
        else => return error.BadConstant,
    }
}

/// Check one flat constant atom against the type of the place it
/// materializes into.  Only a struct field may be optional, which is
/// also the only place `absent` may stand.
fn verifyConstantValue(
    program: *const Program,
    constant: defs.ConstantValue,
    wanted: Type,
    struct_field: bool,
    depth: u32,
) VerifyError!void {
    if (depth > max_constant_depth) return error.BadConstant;

    var expected = wanted;
    if (expected == .optional) {
        if (!struct_field) return error.BadConstant;
        expected = expected.optional.asType();
        // A struct with even an absent optional object field is still
        // object-carrying, so it is outside the flat value set.
        if (expected == .heap or expected == .function) return error.BadConstant;
        if (constant == .absent) return;
    } else if (constant == .absent) {
        return error.BadConstant;
    }

    switch (constant) {
        .boolean => if (expected != .boolean) return error.BadConstant,
        .integer => |held| {
            if (expected == .enumeration) {
                if (!fitsInteger(held, expected.storage())) return error.BadConstant;
                if (!isMember(program, held, expected)) return error.BadConstant;
            } else {
                if (!fitsInteger(held, expected)) return error.BadConstant;
            }
        },
        .float => |held| if (!fitsFloat(held, expected)) return error.BadConstant,
        .str => |index| {
            if ((expected != .str and expected != .bytes) or index >= program.constants.len) {
                return error.BadConstant;
            }
        },
        .strukt => |held| {
            if (expected != .strukt or held.layout != expected.strukt) return error.BadConstant;
            if (held.layout >= program.structs.len) return error.BadConstant;
            const layout = program.structs[held.layout];
            if (held.fields.len != layout.fields.len) return error.BadConstant;
            for (held.fields, layout.fields) |field, declared| {
                try verifyConstantValue(program, field, declared.field_type, true, depth + 1);
            }
        },
        .absent => unreachable, // answered with the optional place above
    }
}

/// Whether an integer constant is a **member** of the enum it lands in.
///
/// The one promise an enum makes is that every value of it is a member
/// (docs/ENUMS.md), and `match` leans on it: with every member named,
/// the last arm is the fallthrough and nothing traps.  So a module that
/// puts a number no member holds in an enum register is refused here,
/// where a hand-made one arrives.
fn isMember(program: *const Program, held: i128, of: Type) bool {
    if (of.enumeration.index >= program.enums.len) return false;
    return program.enums[of.enumeration.index].memberOfValue(held) != null;
}

/// Whether the function `named` really has the shape `signature`
/// claims: the same parameter types and ownership verbs in the same
/// order, and the same answer.  A mismatched type, verb or arity is a
/// module that would call one function through another's spelling.
///
/// Ordinary function values are non-fallible (docs/FUNCTIONS.md, As built),
/// while compiler-generated interface witnesses may name a fallible target.
/// In either case the bound metadata must agree with the target. A function
/// value wears a signature, and the two have to agree — with the receiver,
/// when there is one, standing where the signature does not reach.
///
/// **A bind drops one parameter from the written shape**
/// (docs/BINDING.md D1): the callee's parameter zero is the receiver the
/// value carries, and the signature covers everything after it.  Tying
/// the receiver register's type to that parameter here is what stops a
/// module from calling one struct's method with another's value.
fn expectSignature(
    program: *const Program,
    caller: *const Function,
    defined: *const std.AutoHashMapUnmanaged(Register, void),
    signature: types.Signature,
    named: Instruction.BoundFunction,
) VerifyError!void {
    const callee = program.functions[named.function];
    if (callee.fallible != named.fallible) return error.TypeMismatch;
    if (callee.parameter_count != 0 and callee.locals[0].inout) return error.BadFunction;
    if (callee.locals.len < callee.parameter_count) return error.BadLocal;
    const bound: u32 = if (named.receiver == null) 0 else 1;
    if (signature.parameters.len + bound != callee.parameter_count) return error.BadFunction;
    if (named.receiver) |register| {
        try expectType(try operandType(caller, defined, register), callee.locals[0].local_type);
    }
    for (signature.parameters, 0..) |parameter, index| {
        const callee_index = bound + index;
        try expectType(callee.locals[callee_index].local_type, parameter.value_type);
    }
    try expectType(callee.return_type, signature.result);
}

fn expectType(actual: Type, expected: Type) VerifyError!void {
    if (!actual.eql(expected)) return error.TypeMismatch;
}

// ---------------------------------------------------------------------------
// One instruction
// ---------------------------------------------------------------------------

fn verifyInstruction(
    allocator: Allocator,
    program: *const Program,
    function: *const Function,
    defined: *const std.AutoHashMapUnmanaged(Register, void),
    register: Register,
    instruction: Instruction,
) VerifyError!void {
    const result = function.result_types[register];
    switch (instruction) {
        .const_boolean => try expectType(result, .boolean),
        // A numeric constant travels at the widest member of its
        // family and lands on the register's own width, so what is
        // checked is not the tag but the *value*: it must be exactly
        // representable where it lands, or the constant and its type
        // would disagree about which number this is.
        .const_integer => |held| {
            if (result == .char) {
                if (!fitsChar(held)) return error.BadConstant;
                return;
            }
            if (result == .enumeration) {
                if (!fitsInteger(held, result.storage())) return error.BadConstant;
                if (!isMember(program, held, result)) return error.BadConstant;
                return;
            }
            if (!result.isInteger()) return error.TypeMismatch;
            if (!fitsInteger(held, result)) return error.BadConstant;
        },
        .const_float => |held| {
            if (!result.isFloating()) return error.TypeMismatch;
            if (!fitsFloat(held, result)) return error.BadConstant;
        },
        .const_str => |constant| {
            if (constant >= program.constants.len) return error.BadConstant;
            if (result != .str and result != .bytes) return error.TypeMismatch;
        },
        .const_container => |constant| {
            if (constant >= program.container_constants.len) return error.BadConstant;
            try expectType(result, .{ .heap = program.container_constants[constant].heap });
        },
        // Which function, which signature, and — for a bind — which
        // receiver: `expectSignature` is where the three are tied
        // together, or the module could call one shape through
        // another's spelling (docs/FUNCTIONS.md D2, docs/BINDING.md D1).
        .const_function => |named| {
            if (named.function >= program.functions.len) return error.BadFunction;
            if (result != .function) return error.TypeMismatch;
            if (result.function >= program.signatures.len) return error.BadFunction;
            try expectSignature(program, function, defined, program.signatures[result.function], named);
        },
        .local_get => |local| {
            if (local >= function.locals.len) return error.BadLocal;
            try expectType(result, function.locals[local].local_type);
        },
        .local_set => |set| {
            try expectType(result, .none);
            if (set.local >= function.locals.len) return error.BadLocal;
            const value = try operandType(function, defined, set.value);
            try expectType(value, function.locals[set.local].local_type);
        },
        .binary => |binary| {
            const left = try operandType(function, defined, binary.left);
            const right = try operandType(function, defined, binary.right);
            try expectType(left, binary.operand_type);
            try expectType(right, binary.operand_type);
            // This seam is intentionally retained for old serialized
            // formats even though every current numeric width computes.
            if (isStorageWidth(binary.operand_type)) return error.TypeMismatch;
            if (binary.op.isComparison()) {
                switch (binary.op) {
                    // **Equality is not universal.**  A function value
                    // is the function it names and the receiver it may
                    // carry, and its type cannot say which
                    // (docs/BINDING.md D6); `match` is the only door
                    // into a union (docs/UNION.md D16).  Stage 4
                    // refuses both wherever a comparison reaches one —
                    // through a struct field as readily as at the top
                    // level — and this is the module-format half of the
                    // same rule, which is what makes the runtime
                    // comparator's `.function => unreachable`
                    // unreachable rather than merely unreached.
                    .equal, .not_equal => if (try comparisonIsRefused(
                        allocator,
                        program,
                        binary.operand_type,
                    )) return error.TypeMismatch,
                    else => if (!binary.operand_type.isNumeric() and binary.operand_type != .char and binary.operand_type != .str and binary.operand_type != .bytes)
                        return error.TypeMismatch,
                }
                try expectType(result, .boolean);
            } else {
                const concat = binary.op == .add and (binary.operand_type == .str or binary.operand_type == .bytes);
                if (!binary.operand_type.isNumeric() and !concat) return error.TypeMismatch;
                // `/` is real division and always answers `f64`
                // (docs/NUMERICS.md §2), so `Binary { .divide, .i64 }`
                // is not a shape stage 4 can emit — the quotient that
                // answers a long is `floor_divide`.  Rejecting it here
                // is what lets the runtime and the lowering stop
                // carrying an integer `/` at all.
                if (binary.op == .divide and binary.operand_type.isInteger()) {
                    return error.TypeMismatch;
                }
                // The bit set operates on the integers and nothing
                // else (docs/BITWISE.md D2): a float has no bits a
                // program may see, and a string certainly does not.
                switch (binary.op) {
                    .bit_and, .bit_or, .bit_xor, .shift_left, .shift_right => {
                        if (!binary.operand_type.isInteger()) return error.TypeMismatch;
                    },
                    else => {},
                }
                try expectType(result, binary.operand_type);
            }
        },
        .unary => |unary| {
            const operand = try operandType(function, defined, unary.operand);
            switch (unary.op) {
                .negate => {
                    if (!operand.isNumeric()) return error.TypeMismatch;
                    if (operand.isUnsigned()) return error.TypeMismatch;
                    try expectType(result, operand);
                },
                .bit_not => {
                    if (!operand.isInteger()) return error.TypeMismatch;
                    try expectType(result, operand);
                },
                .logic_not => {
                    try expectType(operand, .boolean);
                    try expectType(result, .boolean);
                },
            }
        },
        // A conversion carries no kind: it goes from the operand's
        // type to the register's, and every pair of *different*
        // numeric types is one the language can spell.  Same-to-same
        // is refused rather than tolerated — it would be a conversion
        // that converts nothing, which is a lowering bug wearing a
        // legal instruction (docs/TYPES.md §3).
        .convert => |operand_register| {
            const operand = try operandType(function, defined, operand_register);
            if (result == .char) {
                if (!operand.isInteger()) return error.TypeMismatch;
                return;
            }
            if (operand == .char) {
                if (result != .u32) return error.TypeMismatch;
                return;
            }
            // **An enum converts to a number and nothing converts to an
            // enum** (docs/ENUMS.md D4, R2): `int(m)` is this
            // instruction reading the member's width, and `Method(n)`
            // is a compare-and-branch tree that answers `Method?`.
            // Same-to-same is refused above except from an enum, where
            // `int(m)` at an `int` backing changes what the value *is*
            // rather than what it holds — the one conversion whose
            // whole content is the type it lands in.
            // `storage()` also exposes a function value's machine
            // representation as `int`; that is an engine fact, not a
            // source conversion.  Only a numeric value or an enum may
            // reach this instruction.
            if (!operand.isNumeric() and operand != .enumeration) return error.TypeMismatch;
            const from = operand.storage();
            if (!from.isNumeric() or !result.isNumeric()) return error.TypeMismatch;
            if (operand != .enumeration and from.eql(result)) return error.TypeMismatch;
        },
        .struct_make => |make| {
            if (make.layout >= program.structs.len) return error.BadStruct;
            const layout = program.structs[make.layout];
            if (make.fields.len != layout.fields.len) return error.BadStruct;
            for (make.fields, layout.fields) |field_register, field| {
                const value = try operandType(function, defined, field_register);
                try expectType(value, field.field_type);
            }
            try expectType(result, .{ .strukt = make.layout });
        },
        .struct_get => |get| {
            if (get.layout >= program.structs.len) return error.BadStruct;
            const layout = program.structs[get.layout];
            if (get.field >= layout.fields.len) return error.BadStruct;
            const target = try operandType(function, defined, get.target);
            try expectType(target, .{ .strukt = get.layout });
            try expectType(result, layout.fields[get.field].field_type);
        },
        .struct_set => |set| {
            if (set.layout >= program.structs.len) return error.BadStruct;
            const layout = program.structs[set.layout];
            if (set.field >= layout.fields.len) return error.BadStruct;
            const target = try operandType(function, defined, set.target);
            try expectType(target, .{ .strukt = set.layout });
            const value = try operandType(function, defined, set.value);
            try expectType(value, layout.fields[set.field].field_type);
            try expectType(result, .{ .strukt = set.layout });
        },
        // The variant trio reads `program.variants` and only that
        // table, exactly as the struct trio reads `program.structs`
        // (docs/UNION.md D8, D18).  A member index out of range is
        // refused the way `isMember` refuses a number no enum member
        // holds — it is where the fallthrough promise is defended.
        .variant_make => |make| {
            if (make.variant >= program.variants.len) return error.BadStruct;
            const declared = program.variants[make.variant];
            if (make.member >= declared.members.len) return error.BadStruct;
            const member = declared.members[make.member];
            if (make.fields.len != member.fields.len) return error.BadStruct;
            for (make.fields, member.fields) |field_register, field| {
                const value = try operandType(function, defined, field_register);
                try expectType(value, field.field_type);
            }
            try expectType(result, .{ .variant = make.variant });
        },
        .variant_tag => |tag| {
            const target = try operandType(function, defined, tag.target);
            if (target != .variant) return error.TypeMismatch;
            try expectType(result, .i64);
        },
        .variant_field => |get| {
            if (get.variant >= program.variants.len) return error.BadStruct;
            const declared = program.variants[get.variant];
            if (get.member >= declared.members.len) return error.BadStruct;
            const member = declared.members[get.member];
            if (get.field >= member.fields.len) return error.BadStruct;
            const target = try operandType(function, defined, get.target);
            try expectType(target, .{ .variant = get.variant });
            try expectType(result, member.fields[get.field].field_type);
        },
        .call => |call| {
            if (call.function >= program.functions.len) return error.BadFunction;
            const callee = program.functions[call.function];
            if (callee.parameter_count != 0 and callee.locals[0].inout) return error.BadFunction;
            if (call.arguments.len != callee.parameter_count) return error.BadFunction;
            for (call.arguments, 0..) |argument, index| {
                const value = try operandType(function, defined, argument);
                try expectType(value, callee.locals[index].local_type);
            }
            if (!result.eql(callee.return_type)) return error.TypeMismatch;
        },
        .call_inout => |call| {
            if (call.function >= program.functions.len) return error.BadFunction;
            if (call.receiver >= function.locals.len) return error.BadLocal;
            const callee = program.functions[call.function];
            if (callee.parameter_count == 0 or !callee.locals[0].inout) return error.BadFunction;
            if (call.arguments.len + 1 != callee.parameter_count) return error.BadFunction;
            try expectType(function.locals[call.receiver].local_type, callee.locals[0].local_type);
            if (function.locals[call.receiver].owns_storage != callee.locals[0].owns_storage) {
                return error.BadLocal;
            }
            for (call.arguments, 1..) |argument, index| {
                const value = try operandType(function, defined, argument);
                try expectType(value, callee.locals[index].local_type);
            }
            if (!result.eql(callee.return_type)) return error.TypeMismatch;
        },
        // A spawn is a call whose arguments cross a runtime boundary
        // (docs/THREADS.md D2), so it is checked as a call plus the two
        // things only a boundary asks: every object parameter must be
        // declared `give`, because nothing can lend across, and the
        // result must be the task shape this callee makes.
        .spawn => |call| {
            if (call.function >= program.functions.len) return error.BadFunction;
            const callee = program.functions[call.function];
            if (callee.parameter_count != 0 and callee.locals[0].inout) return error.BadFunction;
            if (call.arguments.len != callee.parameter_count) return error.BadFunction;
            // Stage 4 refuses these shapes before it emits a spawn: a
            // worker has a different Runtime, so a file or task cannot
            // be re-owned there, and a function value may borrow a
            // receiver that only exists in the spawning runtime.  Keep
            // the same transitive rule at the decoded-MIR boundary;
            // otherwise a hand-built module could reach `copyFrom` with
            // a resource (a defensive trap) or a function value (a
            // borrowed receiver with no valid owner on the far side).
            for (callee.locals[0..callee.parameter_count]) |parameter| {
                if (try typeCarriesWorker(allocator, program, parameter.local_type, .resource) or
                    try typeCarriesWorker(allocator, program, parameter.local_type, .function))
                {
                    return error.BadFunction;
                }
            }
            if (try typeCarriesWorker(allocator, program, callee.return_type, .resource) or
                try typeCarriesWorker(allocator, program, callee.return_type, .function))
            {
                return error.BadFunction;
            }
            for (call.arguments, 0..) |argument, index| {
                const value = try operandType(function, defined, argument);
                try expectType(value, callee.locals[index].local_type);
            }
            if (result != .heap) return error.TypeMismatch;
            if (result.heap >= program.heap_types.len) return error.BadStruct;
            const shape = program.heap_types[result.heap];
            if (shape != .task) return error.TypeMismatch;
            if (!shape.task.result.eql(callee.return_type)) return error.TypeMismatch;
            if (shape.task.fallible != callee.fallible) return error.TypeMismatch;
        },
        // A call through a value is a call whose callee is a register:
        // the callee wears the signature the arguments are checked
        // against, and the result is what that signature answers
        // (docs/FUNCTIONS.md D2).
        .call_indirect => |call| {
            if (call.signature >= program.signatures.len) return error.BadFunction;
            const callee = try operandType(function, defined, call.callee);
            try expectType(callee, .{ .function = call.signature });
            const signature = program.signatures[call.signature];
            if (call.arguments.len != signature.parameters.len) return error.BadFunction;
            for (call.arguments, signature.parameters) |argument, parameter| {
                const value = try operandType(function, defined, argument);
                try expectType(value, parameter.value_type);
            }
            if (!result.eql(signature.result)) return error.TypeMismatch;
        },
        .intrinsic => |intrinsic| try verifyIntrinsic(allocator, program, function, defined, register, intrinsic),
        .heap_new => |new| {
            if (new.heap >= program.heap_types.len) return error.BadStruct;
            const expected_dims: usize = switch (program.heap_types[new.heap]) {
                .array => |shape| shape.rank,
                .list, .map, .builder => 0,
                // Resources enter through their dedicated runtime
                // doors.  Treating one as an ordinary heap allocation
                // leaves the interpreter at `unreachable` and gives
                // the backend no constructor it can lower.
                .file, .task => return error.BadIntrinsic,
            };
            if (new.dims.len != expected_dims) return error.BadStruct;
            for (new.dims) |dimension| {
                const value = try operandType(function, defined, dimension);
                try expectType(value, .i64);
            }
            try expectType(result, .{ .heap = new.heap });
        },
        .jump => |target| {
            try expectType(result, .none);
            if (target >= function.blocks.len) return error.BadBlock;
        },
        .branch => |branch| {
            try expectType(result, .none);
            const condition = try operandType(function, defined, branch.condition);
            try expectType(condition, .boolean);
            if (branch.then_block >= function.blocks.len) return error.BadBlock;
            if (branch.else_block >= function.blocks.len) return error.BadBlock;
        },
        .ret => |value| {
            try expectType(result, .none);
            if (value) |returned| {
                const actual = try operandType(function, defined, returned);
                try expectType(actual, function.return_type);
            } else {
                try expectType(function.return_type, .none);
            }
        },
        .trap => try expectType(result, .none),
        .unwind => {
            try expectType(result, .none);
            if (!function.fallible) return error.NotFallible;
        },
    }
}

/// Can the instruction in `register` come back errored rather than
/// answering?  Only these two shapes can, so only these two may be
/// asked about by `errored` — an `errored` naming anything else is a
/// module that could branch on a word nobody wrote.
///
/// Which intrinsics count is `Intrinsic.isFallible`, the same answer
/// stage 4 asks for before it will let a call site go without `try` or
/// `catch`.  This used to keep its own copy of that list, both guarded
/// by an `else`, so a seventh fallible intrinsic added to one and not
/// the other was silent in both directions.
fn raisesError(program: *const Program, function: *const Function, register: Register) bool {
    return switch (function.instructions[register]) {
        .call => |call| call.function < program.functions.len and
            program.functions[call.function].fallible,
        .call_inout => |call| call.function < program.functions.len and
            program.functions[call.function].fallible,
        .call_indirect => |call| call.fallible,
        .intrinsic => |intrinsic| switch (intrinsic.kind) {
            // The one intrinsic whose fallibility is not a fact about
            // the intrinsic: a wait comes back errored exactly when
            // the function the task carries could, and the task's own
            // shape is where that is written (docs/THREADS.md D4).
            .task_wait => intrinsic.arguments.len == 1 and
                taskShape(program, function, intrinsic.arguments[0]) != null and
                taskShape(program, function, intrinsic.arguments[0]).?.fallible,
            else => intrinsic.kind.isFallible(),
        },
        else => false,
    };
}

/// A fallible producer is not a value-producing call until its outcome has
/// been split.  Stage 5 always writes this compact shape:
///
///     producer; errored producer; [local_set producer]; branch errored
///
/// The `local_set` is present when the call answers a value and parks that
/// answer across the two arms.  Requiring the shape here keeps a decoded MIR
/// module from loading an unwritten result slot after an error, and keeps an
/// ignored error from falling through as if the call had succeeded.  The
/// check is deliberately local to one block because registers do not cross
/// blocks and `errored` is defined to ask the adjacent producer.
fn verifyErrorHandling(
    program: *const Program,
    function: *const Function,
    items: []const Register,
    position: usize,
    register: Register,
) VerifyError!void {
    if (!raisesError(program, function, register)) return;

    const malformed = switch (function.instructions[register]) {
        .intrinsic => error.BadIntrinsic,
        else => error.BadFunction,
    };
    if (position + 1 >= items.len) return malformed;

    const asked_register = items[position + 1];
    switch (function.instructions[asked_register]) {
        .intrinsic => |asked| {
            if (asked.kind != .errored or asked.arguments.len != 1 or
                asked.arguments[0] != register)
            {
                return malformed;
            }
        },
        else => return malformed,
    }

    var branch_position = position + 2;
    if (branch_position < items.len) {
        switch (function.instructions[items[branch_position]]) {
            .local_set => |set| {
                if (set.value != register) return malformed;
                branch_position += 1;
            },
            else => {},
        }
    }
    if (branch_position >= items.len) return malformed;
    switch (function.instructions[items[branch_position]]) {
        .branch => |branch| if (branch.condition != asked_register) return malformed,
        else => return malformed,
    }
}

/// The task shape a register holds, or null when it holds anything
/// else.  Total rather than trusting: a `.lcm` reaches this stage
/// without having passed the analyzer.
fn taskShape(
    program: *const Program,
    function: *const Function,
    register: Register,
) ?@FieldType(types.HeapType, "task") {
    if (register >= function.result_types.len) return null;
    const held = function.result_types[register];
    if (held != .heap or held.heap >= program.heap_types.len) return null;
    const shape = program.heap_types[held.heap];
    return if (shape == .task) shape.task else null;
}

// ---------------------------------------------------------------------------
// One intrinsic call, argument by argument
// ---------------------------------------------------------------------------

fn verifyIntrinsic(
    allocator: Allocator,
    program: *const Program,
    function: *const Function,
    defined: *const std.AutoHashMapUnmanaged(Register, void),
    register: Register,
    call: Instruction.IntrinsicCall,
) VerifyError!void {
    const result = function.result_types[register];
    // `errored` names an *instruction*, not a value: the call it asks
    // about may return nothing at all (`-> !`), so its argument never
    // goes through the operand pass below.
    if (call.kind == .errored) {
        if (call.arguments.len != 1) return error.BadIntrinsic;
        const asked = call.arguments[0];
        if (asked >= function.instructions.len) return error.UndefinedRegister;
        if (!defined.contains(asked)) return error.UndefinedRegister;
        if (!raisesError(program, function, asked)) return error.BadIntrinsic;
        return expectType(result, .boolean);
    }
    // Intrinsics are not limited to an arbitrary small operand count.  The
    // verifier owns an allocator already, so size this scratch to the MIR
    // instruction itself; adding a surface primitive or a future variadic
    // host operation cannot silently become a verifier cap.
    const arguments = try allocator.alloc(Type, call.arguments.len);
    defer allocator.free(arguments);
    for (call.arguments, 0..) |argument, index| {
        arguments[index] = try operandType(function, defined, argument);
    }

    switch (call.kind) {
        // The math builtins compute like operators, so a storage
        // width never reaches one: stage 4 promotes it first (D5), and
        // refusing it here is what makes the runtime's per-width
        // switches total rather than merely lucky.
        .abs => {
            try exactly(arguments, 1);
            if (!arguments[0].isNumeric()) return error.BadIntrinsic;
            if (isStorageWidth(arguments[0])) return error.BadIntrinsic;
            try expectType(result, arguments[0]);
        },
        .min, .max => {
            try exactly(arguments, 2);
            if (!arguments[0].isNumeric()) return error.BadIntrinsic;
            if (isStorageWidth(arguments[0])) return error.BadIntrinsic;
            try expectType(arguments[1], arguments[0]);
            try expectType(result, arguments[0]);
        },
        .clamp => {
            try exactly(arguments, 3);
            if (!arguments[0].isNumeric()) return error.BadIntrinsic;
            if (isStorageWidth(arguments[0])) return error.BadIntrinsic;
            try expectType(arguments[1], arguments[0]);
            try expectType(arguments[2], arguments[0]);
            try expectType(result, arguments[0]);
        },
        .sqrt, .floor, .ceil, .trunc => {
            try exactly(arguments, 1);
            // Whichever float width it was given, and the same one
            // back: `sqrt` of a `float` is a `float` (docs/TYPES.md §9).
            if (!arguments[0].isFloating()) return error.BadIntrinsic;
            if (isStorageWidth(arguments[0])) return error.BadIntrinsic;
            try expectType(result, arguments[0]);
        },
        .compare_i64_f64 => {
            try exactly(arguments, 3);
            // The operator travels as a long because an intrinsic call
            // carries registers and no immediates; which operator it
            // names is trusted exactly as an instruction's type is.
            try expectType(arguments[0], .i64);
            try expectType(arguments[1], .i64);
            try expectType(arguments[2], .f64);
            try expectType(result, .boolean);
        },
        .len => {
            try exactly(arguments, 1);
            // A `file` and a `task` are heap types with no length, and
            // `containers.length` says so with an `unreachable` — so
            // the shape is what decides here, not the tag.
            if (arguments[0] != .str and arguments[0] != .bytes) {
                if (arguments[0] != .heap) return error.BadIntrinsic;
                switch (try heapShape(program, arguments[0])) {
                    .list, .map, .array, .builder => {},
                    .file, .task => return error.BadIntrinsic,
                }
            }
            try expectType(result, .i64);
        },
        .string_slice => {
            try exactly(arguments, 3);
            if (arguments[0] != .str and arguments[0] != .bytes) return error.BadIntrinsic;
            try expectType(arguments[1], .i64);
            try expectType(arguments[2], .i64);
            try expectType(result, arguments[0]);
        },
        .string_byte => {
            try exactly(arguments, 2);
            try expectType(arguments[0], .str);
            try expectType(arguments[1], .i64);
            // The one intrinsic that answers a `byte` (docs/TYPES.md §9).
            try expectType(result, .u8);
        },
        .string_find_byte => {
            try exactly(arguments, 3);
            try expectType(arguments[0], .str);
            // The byte looked for is a `byte`, so "outside 0..255" is
            // refused where it is written instead of trapping where it
            // is read.
            try expectType(arguments[1], .u8);
            try expectType(arguments[2], .i64);
            try expectType(result, .i64);
        },
        .assert_true => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .boolean);
            try expectType(result, .none);
        },
        .trap_message => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .str);
            try expectType(result, .none);
        },
        .exit_program => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .i64);
            try expectType(result, .none);
        },
        .null_object => {
            try exactly(arguments, 0);
            if (result != .heap) return error.BadIntrinsic;
        },
        .none_value => {
            try exactly(arguments, 0);
            if (result != .optional) return error.BadIntrinsic;
        },
        .is_none => {
            try exactly(arguments, 1);
            if (arguments[0] != .optional) return error.BadIntrinsic;
            try expectType(result, .boolean);
        },
        .optional_wrap => {
            try exactly(arguments, 1);
            const widened = Type.optionalOf(arguments[0]) orelse return error.BadIntrinsic;
            try expectType(result, widened);
        },
        .optional_unwrap => {
            try exactly(arguments, 1);
            const payload = arguments[0].held() orelse return error.BadIntrinsic;
            try expectType(result, payload);
        },
        // Settled above, before the operands were typed.
        .errored => return error.BadIntrinsic,
        .error_message => {
            try exactly(arguments, 0);
            try expectType(result, .str);
        },
        .forget => {
            try exactly(arguments, 0);
            try expectType(result, .none);
        },
        .raise_error => {
            if (!function.fallible) return error.NotFallible;
            try exactly(arguments, 1);
            try expectType(arguments[0], .str);
            try expectType(result, .none);
        },
        .own_storage, .drop_storage, .export_storage => {
            try exactly(arguments, 1);
            try expectType(result, arguments[0]);
        },
        // retain/release adjust an object's reference count and answer
        // nothing; the argument is any value (only the objects it names
        // are touched).
        .retain, .release => {
            try exactly(arguments, 1);
            try expectType(result, .none);
        },
        .index_get, .index_set => {
            const reads = call.kind == .index_get;
            const value_slots: usize = if (reads) 0 else 1;
            if (arguments.len < 1) return error.BadIntrinsic;
            if (arguments[0] == .str or arguments[0] == .bytes) {
                if (!reads) return error.BadIntrinsic;
                try exactly(arguments, 2);
                try expectType(arguments[1], .i64);
                try expectType(result, if (arguments[0] == .str) .char else .u8);
                return;
            }
            const element: Type = switch (try heapShape(program, arguments[0])) {
                .list => |item| blk: {
                    try exactly(arguments, 2 + value_slots);
                    try expectType(arguments[1], .i64);
                    break :blk item;
                },
                .map => |pair| blk: {
                    try exactly(arguments, 2 + value_slots);
                    try expectType(arguments[1], pair.key);
                    break :blk pair.value;
                },
                .array => |shape| blk: {
                    try exactly(arguments, 1 + shape.rank + value_slots);
                    for (arguments[1 .. 1 + shape.rank]) |index| try expectType(index, .i64);
                    break :blk shape.element;
                },
                .builder, .file, .task => return error.BadIntrinsic,
            };
            if (reads) {
                try expectType(result, element);
            } else {
                try expectType(arguments[arguments.len - 1], element);
                try expectType(result, .none);
            }
        },
        .list_slice => {
            try exactly(arguments, 3);
            if (try heapShape(program, arguments[0]) != .list) return error.BadIntrinsic;
            try expectType(arguments[1], .i64);
            try expectType(arguments[2], .i64);
            try expectType(result, arguments[0]);
        },
        .append_value => {
            try exactly(arguments, 2);
            switch (try heapShape(program, arguments[0])) {
                .list => |element| try expectType(arguments[1], element),
                .builder => try expectType(arguments[1], .str),
                else => return error.BadIntrinsic,
            }
            try expectType(result, .none);
        },
        .append_ascii => {
            try exactly(arguments, 2);
            if (try heapShape(program, arguments[0]) != .builder) return error.BadIntrinsic;
            try expectType(arguments[1], .i64);
            try expectType(result, .none);
        },
        .pop_value => {
            try exactly(arguments, 1);
            switch (try heapShape(program, arguments[0])) {
                .list => |element| try expectType(result, element),
                else => return error.BadIntrinsic,
            }
        },
        .insert_value => {
            try exactly(arguments, 3);
            switch (try heapShape(program, arguments[0])) {
                .list => |element| {
                    try expectType(arguments[1], .i64);
                    try expectType(arguments[2], element);
                },
                else => return error.BadIntrinsic,
            }
            try expectType(result, .none);
        },
        .remove_entry => {
            try exactly(arguments, 2);
            switch (try heapShape(program, arguments[0])) {
                .list => try expectType(arguments[1], .i64),
                .map => |pair| try expectType(arguments[1], pair.key),
                else => return error.BadIntrinsic,
            }
            try expectType(result, .none);
        },
        .has_key => {
            try exactly(arguments, 2);
            switch (try heapShape(program, arguments[0])) {
                .map => |pair| try expectType(arguments[1], pair.key),
                else => return error.BadIntrinsic,
            }
            try expectType(result, .boolean);
        },
        .key_at => {
            try exactly(arguments, 2);
            switch (try heapShape(program, arguments[0])) {
                .map => |pair| {
                    try expectType(arguments[1], .i64);
                    try expectType(result, pair.key);
                },
                else => return error.BadIntrinsic,
            }
        },
        .value_at => {
            try exactly(arguments, 2);
            switch (try heapShape(program, arguments[0])) {
                .map => |pair| {
                    try expectType(arguments[1], .i64);
                    try expectType(result, pair.value);
                },
                else => return error.BadIntrinsic,
            }
        },
        .dim_size => {
            try exactly(arguments, 2);
            if (try heapShape(program, arguments[0]) != .array) return error.BadIntrinsic;
            try expectType(arguments[1], .i64);
            try expectType(result, .i64);
        },
        .copy_object => {
            try exactly(arguments, 1);
            if (arguments[0] != .heap and arguments[0] != .strukt and arguments[0] != .variant)
                return error.BadIntrinsic;
            try expectType(result, arguments[0]);
        },
        .list_sort, .list_reverse => {
            try exactly(arguments, 1);
            const element: Type = switch (try heapShape(program, arguments[0])) {
                .list => |item| item,
                .array => |shape| if (shape.rank == 1) shape.element else return error.BadIntrinsic,
                else => return error.BadIntrinsic,
            };
            if (call.kind == .list_sort and
                !element.isNumeric() and element != .char and element != .str and element != .bytes)
            {
                return error.BadIntrinsic;
            }
            try expectType(result, .none);
        },
        .list_find, .list_contains => {
            try exactly(arguments, 2);
            const element: Type = switch (try heapShape(program, arguments[0])) {
                .list => |item| item,
                .array => |shape| if (shape.rank == 1) shape.element else return error.BadIntrinsic,
                else => return error.BadIntrinsic,
            };
            try expectType(arguments[1], element);
            try expectType(result, if (call.kind == .list_find)
                Type{ .optional = .i64 }
            else
                .boolean);
        },
        .clear_object => {
            try exactly(arguments, 1);
            switch (try heapShape(program, arguments[0])) {
                .list, .map, .builder => {},
                .array, .file, .task => return error.BadIntrinsic,
            }
            try expectType(result, .none);
        },
        .map_keys => {
            try exactly(arguments, 1);
            switch (try heapShape(program, arguments[0])) {
                .map => |pair| if (!(try heapShape(program, result)).eql(.{ .list = pair.key })) {
                    return error.BadIntrinsic;
                },
                else => return error.BadIntrinsic,
            }
        },
        .map_values => {
            try exactly(arguments, 1);
            switch (try heapShape(program, arguments[0])) {
                .map => |pair| if (!(try heapShape(program, result)).eql(.{ .list = pair.value })) {
                    return error.BadIntrinsic;
                },
                else => return error.BadIntrinsic,
            }
        },
        .map_get => {
            try exactly(arguments, 2);
            switch (try heapShape(program, arguments[0])) {
                .map => |pair| {
                    try expectType(arguments[1], pair.key);
                    // A map value cannot itself be optional, so the
                    // wrap always exists (stage 4 refuses `map(K, V?)`).
                    try expectType(result, Type.optionalOf(pair.value) orelse
                        return error.BadIntrinsic);
                },
                else => return error.BadIntrinsic,
            }
        },
        // The same shape as `map_get` and the same refusal, and the
        // refusal is the point: **a list or an array can never reach
        // this instruction**, so "an index into a sized thing keeps
        // its bounds trap" is a property of the IR rather than of
        // stage 4 remembering to emit the other one.  It is also what
        // makes `mapPlace`'s three non-map arms unreachable.
        .map_place => {
            try exactly(arguments, 3);
            switch (try heapShape(program, arguments[0])) {
                .map => |pair| {
                    try expectType(arguments[1], pair.key);
                    try expectType(arguments[2], pair.value);
                    try expectType(result, pair.value);
                },
                else => return error.BadIntrinsic,
            }
        },
        .array_fill => {
            try exactly(arguments, 2);
            switch (try heapShape(program, arguments[0])) {
                .array => |shape| try expectType(arguments[1], shape.element),
                else => return error.BadIntrinsic,
            }
            try expectType(result, .none);
        },
        .str_value => {
            try exactly(arguments, 1);
            const stringable = switch (arguments[0]) {
                .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f16, .f32, .f64, .char, .boolean, .str => true,
                .heap => (try heapShape(program, arguments[0])) == .builder,
                else => false,
            };
            if (!stringable) return error.BadIntrinsic;
            try expectType(result, .str);
        },
        .bytes_value => {
            try exactly(arguments, 1);
            const accepted = if (arguments[0] == .str)
                true
            else if (arguments[0] == .heap) accepted: {
                const shape = try heapShape(program, arguments[0]);
                break :accepted switch (shape) {
                    .list => |element| element == .u8,
                    .array => |array| array.rank == 1 and array.element == .u8,
                    .map, .builder, .file, .task => false,
                };
            } else false;
            if (!accepted) return error.BadIntrinsic;
            try expectType(result, .bytes);
        },
        // `string(f)` reads a name out of the program's function
        // table: a function value in, text out (docs/FUNCTIONS.md D3).
        .function_name => {
            try exactly(arguments, 1);
            if (arguments[0] != .function) return error.BadIntrinsic;
            try expectType(result, .str);
        },
        .parse_int, .parse_float => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .str);
            try expectType(result, if (call.kind == .parse_int)
                .{ .optional = .i64 }
            else
                .{ .optional = .f64 });
        },
        .parse_str => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .bytes);
            try expectType(result, .{ .optional = .str });
        },
        .chr_code => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .i64);
            try expectType(result, .str);
        },
        .ord_text => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .str);
            try expectType(result, .i64);
        },
        .print, .term_write => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .str);
            try expectType(result, .none);
        },
        .shell_run => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .str);
            try expectType(result, .str);
        },
        .file_read => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .str);
            try expectType(result, .str);
        },
        .file_write => {
            try exactly(arguments, 2);
            try expectType(arguments[0], .str);
            try expectType(arguments[1], .str);
            // Answers nothing: a write that did not land is an error
            // in the channel, not a bool (docs/FAILURE.md).
            try expectType(result, .none);
        },
        // What is at a path, as one of four numbers (0 nothing, 1
        // file, 2 directory, 3 other).  A `long` and not an enum:
        // the runtime is never handed the program's type table, so
        // `std.files` is where the codes get their names.
        .path_kind => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .str);
            try expectType(result, .i64);
        },
        .gpu_backend => {
            try exactly(arguments, 0);
            try expectType(result, .i64);
        },
        .ui_window_open => {
            try exactly(arguments, 3);
            try expectType(arguments[0], .str);
            try expectType(arguments[1], .i64);
            try expectType(arguments[2], .i64);
            if (try heapShape(program, result) != .file) return error.BadIntrinsic;
        },
        .ui_window_surface => {
            try exactly(arguments, 1);
            if (try heapShape(program, arguments[0]) != .file) return error.BadIntrinsic;
            if (try heapShape(program, result) != .file) return error.BadIntrinsic;
        },
        .gpu_surface_size => {
            try exactly(arguments, 2);
            if (try heapShape(program, arguments[0]) != .file) return error.BadIntrinsic;
            try expectType(arguments[1], .i64);
            try expectType(result, .i64);
        },
        .gpu_surface_clear => {
            try exactly(arguments, 5);
            if (try heapShape(program, arguments[0]) != .file) return error.BadIntrinsic;
            for (arguments[1..]) |argument| try expectType(argument, .i64);
            try expectType(result, .none);
        },
        .gpu_surface_fill_rect => {
            try exactly(arguments, 9);
            if (try heapShape(program, arguments[0]) != .file) return error.BadIntrinsic;
            for (arguments[1..]) |argument| try expectType(argument, .i64);
            try expectType(result, .none);
        },
        .gpu_surface_present => {
            try exactly(arguments, 1);
            if (try heapShape(program, arguments[0]) != .file) return error.BadIntrinsic;
            try expectType(result, .none);
        },
        .term_rows, .term_cols => {
            try exactly(arguments, 0);
            try expectType(result, .i64);
        },
        .term_event_data => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .i64);
            try expectType(result, .i64);
        },
        .term_clear, .term_flush => {
            try exactly(arguments, 0);
            try expectType(result, .none);
        },
        .term_move => {
            try exactly(arguments, 2);
            try expectType(arguments[0], .i64);
            try expectType(arguments[1], .i64);
            try expectType(result, .none);
        },
        .term_style => {
            try exactly(arguments, 3);
            try expectType(arguments[0], .i64);
            try expectType(arguments[1], .i64);
            try expectType(arguments[2], .boolean);
            try expectType(result, .none);
        },
        .key_text => {
            try exactly(arguments, 0);
            try expectType(result, .str);
        },
        .key_read => {
            // `string?`: a keyboard that has run dry has nothing to
            // hand over, which is absence and not news (docs/FAILURE.md).
            try exactly(arguments, 0);
            try expectType(result, .{ .optional = .str });
        },
        .read_line, .env_get => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .str);
            try expectType(result, .{ .optional = .str });
        },
        .print_error => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .str);
            try expectType(result, .none);
        },
        .clock_ms, .epoch_ms => {
            try exactly(arguments, 0);
            try expectType(result, .i64);
        },
        // The machine's facts: nothing to ask with, a number back.
        .os_total_memory, .os_available_memory, .os_cpu_count => {
            try exactly(arguments, 0);
            try expectType(result, .i64);
        },
        .sleep_ms => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .i64);
            try expectType(result, .none);
        },
        .file_append, .file_rename => {
            try exactly(arguments, 2);
            try expectType(arguments[0], .str);
            try expectType(arguments[1], .str);
            // Answers nothing: what the world said travels in the
            // error channel, like every other file service.
            try expectType(result, .none);
        },
        .file_delete, .dir_create => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .str);
            // Answers nothing: whether the world took it travels in
            // the error channel, like every other file service.
            try expectType(result, .none);
        },
        .dir_list => {
            try exactly(arguments, 1);
            try expectType(arguments[0], .str);
            const shape = try heapShape(program, result);
            if (shape != .list or shape.list != .str) return error.BadIntrinsic;
        },
        // The byte channel (docs/BYTES.md).  The buffer is an
        // `array(byte, _)` in both directions and is checked here
        // rather than trusted, because a `.lcm` reaches this stage
        // without ever passing the analyzer: the runtime reads those
        // cells as raw bytes, and a run of `Value`s read that way is
        // the one shape damaged IR must not be able to ask for.
        .file_open => {
            try exactly(arguments, 2);
            try expectType(arguments[0], .str);
            try expectType(arguments[1], .i64);
            if (try heapShape(program, result) != .file) return error.BadIntrinsic;
        },
        .handle_read => {
            try exactly(arguments, 2);
            if (try heapShape(program, arguments[0]) != .file) return error.BadIntrinsic;
            try expectByteBuffer(program, arguments[1]);
            try expectType(result, .i64);
        },
        .handle_write => {
            try exactly(arguments, 3);
            if (try heapShape(program, arguments[0]) != .file) return error.BadIntrinsic;
            try expectByteBuffer(program, arguments[1]);
            try expectType(arguments[2], .i64);
            try expectType(result, .i64);
        },
        // `t.wait()` — one task in, the worker's result out
        // (docs/THREADS.md D4).  The result type is read out of the
        // task's own shape, which is also where its fallibility is: a
        // task is a call in flight and carries what the call answers.
        .task_wait => {
            try exactly(arguments, 1);
            const held = arguments[0];
            if (held != .heap) return error.BadIntrinsic;
            if (held.heap >= program.heap_types.len) return error.BadIntrinsic;
            const shape = program.heap_types[held.heap];
            if (shape != .task) return error.BadIntrinsic;
            if (!result.eql(shape.task.result)) return error.BadIntrinsic;
        },
        .handle_flush => {
            try exactly(arguments, 1);
            if (try heapShape(program, arguments[0]) != .file) return error.BadIntrinsic;
            try expectType(result, .none);
        },
    }
}

/// The one buffer shape the byte channel reads and writes: a rank-1
/// `array(byte, n)`, whose cells are packed bytes and nothing else.
fn expectByteBuffer(program: *const Program, of: Type) VerifyError!void {
    const shape = try heapShape(program, of);
    if (shape != .array) return error.BadIntrinsic;
    if (shape.array.element != .u8 or shape.array.rank != 1) return error.BadIntrinsic;
}

// ---------------------------------------------------------------------------
// Small shared checks
// ---------------------------------------------------------------------------

fn exactly(arguments: []const Type, count: usize) VerifyError!void {
    if (arguments.len != count) return error.BadIntrinsic;
}

/// Whether comparing two values of `of` with `==` would reach
/// something equality has no answer for: a function value
/// (docs/BINDING.md D6) or a union (docs/UNION.md D16).
///
/// This is `semantics/shapes.zig`'s `incomparablePart` over the
/// module's own tables — one rule, two tables, because a decoded
/// module has no analyzer to ask.  The frontier is `==`'s: an object
/// handle compares by identity and nothing inside it is read, so the
/// walk descends a struct's field run, a union's members and an
/// optional's payload and stops at a `.heap`.
///
/// Iterative and visited-checked, because the *type* graph may be
/// cyclic where no value is (`struct Node: next: Node?`).  Every tag
/// that compares as itself answers without allocating, so the ordinary
/// numeric and string comparison pays nothing.
fn comparisonIsRefused(allocator: Allocator, program: *const Program, of: Type) VerifyError!bool {
    switch (of) {
        .strukt, .variant, .function, .optional => {},
        else => return false,
    }

    const seen = try allocator.alloc(bool, program.structs.len);
    defer allocator.free(seen);
    @memset(seen, false);

    var pending: std.ArrayList(Type) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, of);

    var next: usize = 0;
    while (next < pending.items.len) : (next += 1) {
        // Bound before the arms run: appending inside one may move the
        // backing array, and a capture into it would then be stale.
        const current = pending.items[next];
        switch (current) {
            .function, .variant => return true,
            .optional => |payload| try pending.append(allocator, payload.asType()),
            .strukt => |layout| {
                if (layout >= program.structs.len) return error.BadStruct;
                if (seen[layout]) continue;
                seen[layout] = true;
                for (program.structs[layout].fields) |field| {
                    try pending.append(allocator, field.field_type);
                }
            },
            else => {},
        }
    }
    return false;
}

/// Whether a type has a value-storage representation a local may own.
/// Objects are heap rows, not bytes in the local slot; only strings and
/// value runs (including their optional wrapper) use `Local.owns_storage`.
/// A struct/variant/function is conservatively storage-bearing even when a
/// particular zero-width instance happens to need no allocation: that is
/// the representation contract the lowerer records.
fn typeCanOwnStorage(of: Type) bool {
    return switch (of) {
        .str, .bytes, .strukt, .variant, .function => true,
        .optional => |payload| typeCanOwnStorage(payload.asType()),
        .none,
        .boolean,
        .u8,
        .u16,
        .u32,
        .u64,
        .i8,
        .i16,
        .i32,
        .i64,
        .f16,
        .f32,
        .f64,
        .char,
        .heap,
        .enumeration,
        => false,
    };
}

const WorkerCarry = enum { resource, function };

/// Whether a type graph contains a value that cannot cross a worker
/// boundary.  The source checker asks the same question through
/// `shapes.carries`; this copy belongs here because a decoded module has
/// not come through that checker.  Unlike `typeCarriesObjects`, a heap
/// handle is not automatically a match: lists, maps and arrays must be
/// opened to find a nested function, file, or task.
fn typeCarriesWorker(
    allocator: Allocator,
    program: *const Program,
    of: Type,
    sought: WorkerCarry,
) VerifyError!bool {
    const seen_structs = try allocator.alloc(bool, program.structs.len);
    defer allocator.free(seen_structs);
    @memset(seen_structs, false);

    const seen_variants = try allocator.alloc(bool, program.variants.len);
    defer allocator.free(seen_variants);
    @memset(seen_variants, false);

    const seen_heaps = try allocator.alloc(bool, program.heap_types.len);
    defer allocator.free(seen_heaps);
    @memset(seen_heaps, false);

    var pending: std.ArrayList(Type) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, of);

    while (pending.items.len != 0) {
        const current = pending.pop().?;
        switch (current) {
            .function => if (sought == .function) return true,
            .optional => |payload| try pending.append(allocator, payload.asType()),
            .strukt => |index| {
                if (index >= program.structs.len) return error.BadStruct;
                if (seen_structs[index]) continue;
                seen_structs[index] = true;
                for (program.structs[index].fields) |field| {
                    try pending.append(allocator, field.field_type);
                }
            },
            .variant => |index| {
                if (index >= program.variants.len) return error.BadStruct;
                if (seen_variants[index]) continue;
                seen_variants[index] = true;
                for (program.variants[index].members) |member| {
                    for (member.fields) |field| {
                        try pending.append(allocator, field.field_type);
                    }
                }
            },
            .heap => |index| {
                if (index >= program.heap_types.len) return error.BadStruct;
                if (seen_heaps[index]) continue;
                seen_heaps[index] = true;
                switch (program.heap_types[index]) {
                    .file, .task => if (sought == .resource) return true,
                    .list => |element| try pending.append(allocator, element),
                    .map => |pair| {
                        try pending.append(allocator, pair.key);
                        try pending.append(allocator, pair.value);
                    },
                    .array => |shape| try pending.append(allocator, shape.element),
                    .builder => {},
                }
            },
            .none,
            .boolean,
            .u8,
            .u16,
            .u32,
            .u64,
            .i8,
            .i16,
            .i32,
            .i64,
            .f16,
            .f32,
            .f64,
            .char,
            .str,
            .bytes,
            .enumeration,
            => {},
        }
    }
    return false;
}

fn heapShape(program: *const Program, of: Type) VerifyError!types.HeapType {
    if (of != .heap) return error.BadIntrinsic;
    if (of.heap >= program.heap_types.len) return error.BadStruct;
    return program.heap_types[of.heap];
}
