//! Call resolution: which callable a call site names, which slot each
//! argument fills, and what the answer is typed as.
//!
//! Every call path in the language flattens to the same two questions,
//! and this file is where both are answered once.  *Which surface* —
//! a declared function, a function value, a spawned worker, a method
//! on a struct or an enum, a method on a container the language
//! supplies, or a std module's routed call.  *Which slots* — the
//! `CallSlot` run a declaration or a builtin table row both flatten
//! to, the argument-to-slot rule the checker and the landing pass
//! share (`argumentSlot`, docs/ARGS.md), the defaults, and the count
//! and name refusals.
//!
//! It is a file because that pair is one algorithm serving nine
//! spellings: keeping them together is what makes it impossible for
//! two call forms to disagree about which slot an argument filled.
//! Construction and conversion — the call-shaped forms that build a
//! value rather than run a body — are `construct.zig`.

const std = @import("std");
const source_mod = @import("../source.zig");
const ast = @import("../parse.zig").ast;
const types = @import("../support/types.zig");
const conversionNamed = types.conversionNamed;
const mir = @import("../mir.zig");
const helpers = @import("helpers.zig");
const nodes = @import("../hir.zig").nodes;
const builtins_mod = @import("builtins.zig");
const Builtin = builtins_mod.Builtin;
const builtins = builtins_mod.builtins;
const string_methods = builtins_mod.string_methods;
const list_methods = builtins_mod.list_methods;
const array_methods = builtins_mod.array_methods;
const map_methods = builtins_mod.map_methods;
const builder_methods = builtins_mod.builder_methods;
const file_methods = builtins_mod.file_methods;
const task_methods = builtins_mod.task_methods;
const context = @import("context.zig");
const Error = context.Error;
const Span = source_mod.Span;
const Type = types.Type;
const LocalId = mir.LocalId;

const builder = @import("builder.zig");
const construct = @import("construct.zig");
const effects = @import("effects.zig");
const expressions = @import("expressions.zig");
const ledger = @import("ledger.zig");
const recorder = @import("recorder.zig");
const refusals = @import("refusals.zig");
const naming = @import("naming.zig");
const resolve = @import("resolve.zig");
const shapes = @import("shapes.zig");
const signatures = @import("signatures.zig");
const FunctionBuilder = builder.FunctionBuilder;
const OperandRun = builder.OperandRun;
const RecordedOperand = recorder.RecordedOperand;
const ShapePosition = builder.ShapePosition;
const Typed = builder.Typed;

/// One slot of a callable surface, as name resolution sees it
/// (docs/ARGS.md): what the slot is called, whether a call site may
/// name it — a method receiver is not nameable (D7) — and whether it
/// carries a default (D2).  A user declaration and a builtin's table
/// row both flatten to this, which is what lets one resolver serve
/// every call path (D10).
const CallSlot = struct {
    name: []const u8,
    nameable: bool = true,
    defaulted: bool = false,
};

/// The slot argument `index` of `arguments` fills, with no reporting
/// (docs/ARGS.md D4, D5): positional arguments fill slots left to
/// right, a name fills the slot that spells it, and a receiver slot
/// is never filled by name.  `hidden` is how many leading slots the
/// call site does not write — 1 in the method form, whose receiver
/// stands in front of the dot; 0 otherwise.  The answer indexes the
/// declared list, `hidden` included.  Null where the call is
/// malformed; `resolveSlots` is the half that says how.
///
/// Two callers, one rule: `landsOn` asks it mid-batch so a literal
/// lands at the type of the slot it will fill, and `resolveSlots` asks
/// it while checking — one implementation, so the two can never
/// disagree about which slot that is.
pub fn argumentSlot(
    slots: []const CallSlot,
    hidden: usize,
    arguments: []const ast.Argument,
    index: usize,
) ?usize {
    const argument = arguments[index];
    if (argument.name) |written| {
        for (slots[hidden..], hidden..) |candidate, slot| {
            if (!candidate.nameable) continue;
            if (std.mem.eql(u8, candidate.name, written)) return slot;
        }
        return null;
    }
    var positional: usize = 0;
    for (arguments[0..index]) |earlier| {
        if (earlier.name == null) positional += 1;
    }
    const slot = hidden + positional;
    return if (slot < slots.len) slot else null;
}

/// How many of a surface's slots carry a default — the second number
/// in the count sentence, and the suffix a call may omit
/// (docs/ARGS.md D3).
fn defaultCount(slots: []const CallSlot) usize {
    var count: usize = 0;
    for (slots) |slot| {
        if (slot.defaulted) count += 1;
    }
    return count;
}

/// A declaration's parameters flattened to the resolver's
/// vocabulary: a receiver slot is not nameable (D7), and a slot
/// with a folded default says so.  Arena-owned.
pub fn declarationSlots(
    self: *FunctionBuilder,
    info: context.FunctionDeclInfo,
) Error![]CallSlot {
    const surface = try self.arena().alloc(CallSlot, info.parameter_types.len);
    const hidden: usize = if (info.receiver == .not) 0 else 1;
    if (hidden == 1) {
        surface[0] = .{ .name = "self", .nameable = false };
    }
    for (info.declaration.parameters, surface[hidden..], info.parameter_defaults[hidden..]) |parameter, *slot, default| {
        slot.* = .{
            .name = parameter.name,
            .defaulted = default != null,
        };
    }
    return surface;
}

/// A builtin's table row flattened the same way — the table is its
/// signature (docs/ARGS.md §3).  Arena-owned.
pub fn builtinSlots(self: *FunctionBuilder, matched: Builtin) Error![]CallSlot {
    const surface = try self.arena().alloc(CallSlot, matched.parameters.len);
    for (matched.parameters, surface) |parameter, *slot| {
        slot.* = .{ .name = parameter.name, .defaulted = parameter.default != null };
    }
    return surface;
}

/// Which parameter slot each written argument fills — the name
/// resolution of docs/ARGS.md, shared by every spelling of a user
/// call.  The rules, each with its own sentence: positional
/// arguments fill slots left to right and **the first named
/// argument ends the positional run** (D4), names may reorder
/// (D5), a slot is filled once, and `self` is not a nameable
/// argument (D7).
///
/// `surface` is the declared list flattened to `CallSlot`s;
/// `hidden` is how many of its leading slots the call site does
/// not write — 1 in the method form, whose receiver stands in
/// front of the dot; 0 otherwise.  The answers index the declared
/// list, `hidden` included, so they index `parameter_types`
/// directly.  `seen` has one flag per declared slot; the caller
/// pre-marks the hidden ones.  Count mistakes point at the call
/// (`span`); name mistakes point at the argument.  Null after
/// reporting; arena-owned otherwise.
pub fn resolveSlots(
    self: *FunctionBuilder,
    callee: []const u8,
    code: []const u8,
    surface: []const CallSlot,
    hidden: usize,
    call_arguments: []const ast.Argument,
    seen: []bool,
    span: Span,
) Error!?[]u32 {
    const slots = try self.arena().alloc(u32, call_arguments.len);
    var positional: usize = 0;
    var named = false;
    for (call_arguments, slots, 0..) |argument, *filled, index| {
        if (argument.name == null and named) {
            // D4: the strict rule, Kotlin 1.3's — the first named
            // argument ends the positional run, so this argument
            // has no slot to count into.  Name the first slot
            // still open, which is the fix.
            for (surface, seen) |candidate, given| {
                if (given or !candidate.nameable) continue;
                try self.fail(code, argument.span, "a positional argument cannot follow a named one; write {s} = …", .{candidate.name});
                return null;
            }
            try self.fail(code, argument.span, "a positional argument cannot follow a named one", .{});
            return null;
        }
        const slot = argumentSlot(surface, hidden, call_arguments, index) orelse {
            if (argument.name != null) {
                try failUnknownParameter(self, callee, code, surface, hidden, argument);
                return null;
            }
            // A positional argument past the last slot: the count
            // sentence, which is about the call and not about any
            // one argument.
            try failArgumentCount(self, callee, code, surface, hidden, call_arguments.len, span);
            return null;
        };
        if (argument.name) |written| {
            named = true;
            if (seen[slot]) {
                if (slot < hidden + positional) {
                    try self.fail(code, argument.span, "{s} was given twice, by position and by name", .{written});
                } else {
                    try self.fail(code, argument.span, "{s} was given twice", .{written});
                }
                return null;
            }
        } else {
            positional += 1;
        }
        seen[slot] = true;
        filled.* = @intCast(slot);
    }
    return slots;
}

/// The named argument that names no parameter (docs/ARGS.md §8):
/// `self` gets the receiver sentence, anything else the
/// did-you-mean, and the enumerate-the-surface fallback when
/// nothing is close enough.
fn failUnknownParameter(
    self: *FunctionBuilder,
    callee: []const u8,
    code: []const u8,
    surface: []const CallSlot,
    hidden: usize,
    argument: ast.Argument,
) Error!void {
    const written = argument.name.?;
    if (std.mem.eql(u8, written, "self")) {
        if (hidden != 0) {
            try self.fail("luce.sema.self", argument.span, "self is the receiver; it is written in front of the dot, not named", .{});
            return;
        }
        if (surface.len != 0 and !surface[0].nameable) {
            try self.fail("luce.sema.self", argument.span, "self is the receiver, not a parameter: write {s}({s}, …)", .{
                callee,
                try writtenTarget(self, argument.value),
            });
            return;
        }
    }
    var suggestion = helpers.Suggestion.init(written);
    for (surface[hidden..]) |candidate| {
        if (!candidate.nameable) continue;
        suggestion.offer(candidate.name);
    }
    if (suggestion.best()) |closest| {
        try self.fail(code, argument.span, "{s} has no parameter {s}; did you mean {s}?", .{ callee, written, closest });
        return;
    }
    var takes: std.ArrayList(u8) = .empty;
    defer takes.deinit(self.temporary());
    for (surface[hidden..]) |candidate| {
        if (!candidate.nameable) continue;
        if (takes.items.len != 0) try takes.appendSlice(self.temporary(), ", ");
        try takes.appendSlice(self.temporary(), candidate.name);
    }
    if (takes.items.len == 0) {
        try self.fail(code, argument.span, "{s} has no parameter {s}; it takes no arguments", .{ callee, written });
        return;
    }
    try self.fail(code, argument.span, "{s} has no parameter {s} (takes {s})", .{ callee, written, takes.items });
}

/// The count sentence: how many arguments the call site may write,
/// against how many it wrote — and, where the signature has
/// defaults, how many of its slots have one (docs/ARGS.md §8).
fn failArgumentCount(
    self: *FunctionBuilder,
    callee: []const u8,
    code: []const u8,
    surface: []const CallSlot,
    hidden: usize,
    written_count: usize,
    span: Span,
) Error!void {
    const defaulted = defaultCount(surface);
    const takes = surface.len - hidden;
    if (defaulted != 0) {
        const required = takes - defaulted;
        try self.fail(code, span, "{s} takes {d} argument{s} and {d} with a default, got {d}", .{
            callee,
            required,
            helpers.plural(required),
            defaulted,
            written_count,
        });
        return;
    }
    try self.fail(code, span, "{s} takes {d} argument{s}, got {d}", .{
        callee,
        takes,
        helpers.plural(takes),
        written_count,
    });
}

/// Every required slot the call left unfilled, named at once —
/// never the first only, for `writeMissingFields`' reason — and a
/// slot with a default is never missing: it is filled from the
/// declaration (docs/ARGS.md D2).  True when nothing is missing.
pub fn checkRequiredSlots(
    self: *FunctionBuilder,
    callee: []const u8,
    code: []const u8,
    surface: []const CallSlot,
    seen: []const bool,
    span: Span,
) Error!bool {
    var missing: usize = 0;
    for (surface, seen) |candidate, given| {
        if (given or candidate.defaulted) continue;
        missing += 1;
    }
    if (missing == 0) return true;
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(self.temporary());
    var written: usize = 0;
    for (surface, seen) |candidate, given| {
        if (given or candidate.defaulted) continue;
        if (written != 0) {
            if (missing > 2) try names.appendSlice(self.temporary(), ",");
            try names.appendSlice(self.temporary(), " ");
            if (written + 1 == missing) try names.appendSlice(self.temporary(), "and ");
        }
        try names.appendSlice(self.temporary(), candidate.name);
        written += 1;
    }
    try self.fail(code, span, "{s} is missing {s}", .{ callee, names.items });
    return false;
}

pub fn lowerCall(
    self: *FunctionBuilder,
    call: ast.Call,
    as_statement: bool,
    fallible_allowed: bool,
    shape_position: ShapePosition,
    wanted: ?Type,
) Error!?Typed {
    // A local of function type is called through
    // (docs/FUNCTIONS.md D2).  First, because a local is what the
    // name means wherever one exists — and no local can be called
    // one of the reserved names the builtins below answer to.
    if (std.mem.indexOfScalar(u8, call.callee, '.') == null) {
        if (self.findLocal(call.callee) != null) {
            return lowerNamedValueCall(self, call, as_statement);
        }
    }
    // Builtins and conversions are bare names and take priority;
    // reserved names keep user declarations out of their way.
    if (std.mem.indexOfScalar(u8, call.callee, '.') == null) {
        if (conversionNamed(call.callee) != null) return construct.lowerConvert(self, call);
        switch (try construct.lowerIntrinsic(self, call, as_statement, fallible_allowed, wanted)) {
            .not_builtin => {},
            .failed => return null,
            .value => |value| return value,
        }
    }

    const resolved = (try self.resolveDeclared(call.callee, call.span, call.origin)) orelse
        return null;
    if (self.analyzer.alias_names.get(resolved)) |alias_index| {
        return lowerAliasCall(self, call, alias_index, as_statement, fallible_allowed, shape_position);
    }
    if (self.analyzer.struct_names.get(resolved)) |layout_index| {
        return lowerNominalConstruct(
            self,
            layout_index,
            call.callee,
            call.arguments,
            call.span,
            as_statement,
            fallible_allowed,
            shape_position,
        );
    }
    if (self.analyzer.interface_names.get(resolved)) |interface_index| {
        return construct.lowerConstruct(
            self,
            call.arguments,
            call.span,
            self.analyzer.interface_decls.items[interface_index].layout,
        );
    }
    if (self.analyzer.enum_names.get(resolved)) |enum_index| {
        return construct.lowerEnumOfNumber(self, call.callee, call.arguments, call.span, enum_index);
    }
    // A union has no `Shape(n)` and no bare construction: a member
    // is the only way in (docs/UNION.md D1, D4).
    if (self.analyzer.variant_names.get(resolved)) |variant_index| {
        return construct.failVariantAsCallee(self, call.callee, variant_index, call.span);
    }
    const function_index = self.analyzer.function_names.get(resolved) orelse {
        try refusals.failUnknownFunction(self, call.callee, call.span);
        return null;
    };
    return lowerUserCall(
        self,
        function_index,
        call.callee,
        call.arguments,
        call.span,
        as_statement,
        fallible_allowed,
        shape_position,
        null,
    );
}

/// `EXPR(a, b)` — a call **through a function value**
/// (docs/FUNCTIONS.md D2, D5), and the one path every call whose head
/// does not name a declaration takes: a bare local's name, an element,
/// a field read through a grouping, the answer of another call.
///
/// The signature is what a direct call's declaration is: it says
/// the arity, the argument types and the verb each object argument
/// travels by, and those are checked here exactly as `lowerUserCall`
/// checks them against a declaration.  What it does *not* carry is
/// names and defaults, because a type has neither — so a named
/// argument is refused where it is written rather than matched
/// against a parameter name that does not exist.
///
/// `callee` is already lowered, because the callee is the run's first
/// operand: what the reader wrote first is checked first, and a
/// mistake in it is reported before anything is said about arguments
/// whose types it decides.
fn lowerValueCall(
    self: *FunctionBuilder,
    callee: Typed,
    written_at: *const ast.Expression,
    arguments: []const ast.Argument,
    span: Span,
    as_statement: bool,
) Error!?Typed {
    const callee_type = callee.value_type;
    const written = try calleeSpelling(self, written_at);
    if (callee_type != .function) {
        // The storable form — `(func(...) -> R)?` — is callable
        // exactly where the flow analysis has proved the value is
        // there, and **only a local or a parameter can be proved**
        // (docs/LANGUAGE.md: a field or an element can change between
        // the test and the use).  So the refusal teaches the three
        // lines that always work rather than the narrowing that
        // sometimes cannot.
        if (callee_type == .optional and callee_type.optional == .function) {
            // A name that could have been narrowed and was not is told
            // to narrow it, which is the shorter fix and the one it can
            // take.  Everything else takes the three-line one.
            if (written_at.* == .name) {
                try self.fail(
                    "luce.sema.call",
                    span,
                    "{s} is {s} and may hold none; test it first (if {s} != none:) or supply a fallback ({s} else …)",
                    .{ written, try self.analyzer.typeName(callee_type), written, written },
                );
                return null;
            }
            try failAbsentCallee(self, written, bindingName(written_at), callee_type, span);
            return null;
        }
        try self.fail(
            "luce.sema.call",
            span,
            "{s} is {s}, which is not a function; only a func(...) value can be called",
            .{ written, try self.analyzer.typeName(callee_type) },
        );
        return null;
    }
    const signature = self.analyzer.signatures.items[callee_type.function];
    for (arguments) |argument| {
        if (argument.name) |named| {
            try self.fail(
                "luce.sema.call",
                argument.span,
                "a function type has no parameter names, so {s} cannot be named here",
                .{named},
            );
            return null;
        }
    }
    if (arguments.len != signature.parameters.len) {
        try self.fail(
            "luce.sema.call",
            span,
            "{s} is {s} and takes {d} argument{s}, got {d}",
            .{
                written,
                try self.analyzer.typeName(callee_type),
                signature.parameters.len,
                if (signature.parameters.len == 1) "" else "s",
                arguments.len,
            },
        );
        return null;
    }
    // The residual hazard copy-on-store leaves open (docs/STRINGS.md),
    // asked of the **callee**: it may be a borrow of an element's or a
    // field's two-slot run, and an argument still to come could free
    // it.  The question is the operand walk's own, asked here because
    // the callee is lowered before the batch it is not part of; the
    // decision travels on the resolved callee and lower emits it there.
    var callee_value = callee;
    var callee_copy = false;
    if (shapes.ownsStorage(self.analyzer, callee_type) and callee_value.provenance() == .view) {
        for (arguments) |argument| {
            if (!effects.mayMutateContainers(argument.value)) continue;
            callee_value.rewritten = .fresh;
            callee_copy = true;
            try ledger.parkFreshStorage(self, callee_value, written_at.span());
            break;
        }
    }
    const operand_expressions = try self.arena().alloc(*ast.Expression, arguments.len);
    const places = try self.arena().alloc(Type, arguments.len);
    for (arguments, operand_expressions, places, signature.parameters) |argument, *expression, *place, parameter| {
        expression.* = argument.value;
        place.* = parameter.value_type;
    }
    const run = (try self.lowerOperandsIntoTracking(operand_expressions, .{ .places = places })) orelse return null;
    const values = run.values;
    const entries = try self.arena().alloc(RecordedOperand, values.len);
    for (values, signature.parameters, 0..) |value, parameter, index| {
        const fitted = (try self.fit(value, parameter.value_type)) orelse {
            try self.fail("luce.sema.type", arguments[index].span, "argument {d} of {s} is {s}, got {s}{s}", .{
                index + 1,
                written,
                try self.analyzer.typeName(parameter.value_type),
                try self.analyzer.typeName(value.value_type),
                try refusals.mismatchAdvice(self, parameter.value_type, value.value_type, operand_expressions[index]),
            });
            return null;
        };
        // A function type has no names and no defaults, so the
        // batch is positional whole: slot i is operand i.
        entries[index] = .{
            .node = fitted.node,
            .slot = @intCast(index),
            .copied = run.copied[index],
        };
    }
    if (signature.result == .none and !as_statement) {
        try self.fail("luce.sema.call", span, "{s} returns nothing", .{written});
        return null;
    }
    return .{
        .node = try recorder.recordCallNode(
            self,
            .{ .indirect = .{
                .callee = callee_value.node,
                .signature = callee_type.function,
                .borrow_copy = callee_copy,
            } },
            entries,
            entries.len,
            false,
            signature.result,
            span,
        ),
        .value_type = signature.result,
    };
}

/// `EXPRESSION(arguments)` — the call suffix (docs/FUNCTIONS.md).
///
/// The callee is an ordinary expression, lowered the ordinary way, so
/// its narrowing, its poison check and the statement temporary a fresh
/// function value is parked in are all the walk's existing answers
/// rather than a second set of them.
pub fn lowerValueCallExpression(
    self: *FunctionBuilder,
    written: ast.ValueCall,
    as_statement: bool,
) Error!?Typed {
    const callee = (try self.lowerExpression(written.callee, false)) orelse return null;
    return lowerValueCall(self, callee, written.callee, written.arguments, written.span, as_statement);
}

/// `f(a, b)` where `f` is a local holding a function value — the same
/// call, reached through the name the primary parsed
/// (docs/FUNCTIONS.md D2).  The name is read as any other read of it
/// is, which is what keeps the narrowed form (docs/BINDING.md D7) and
/// the poison check from having a second implementation here.
fn lowerNamedValueCall(
    self: *FunctionBuilder,
    call: ast.Call,
    as_statement: bool,
) Error!?Typed {
    const name = try self.arena().create(ast.Expression);
    name.* = .{ .name = .{ .text = call.callee, .span = call.span } };
    const callee = (try self.lowerExpression(name, false)) orelse return null;
    return lowerValueCall(self, callee, name, call.arguments, call.span, as_statement);
}

/// What a diagnostic calls the thing in front of a call suffix.
///
/// Stage 4 has no source text, so the spelling is rebuilt from what
/// was written — `rows.render`, `actions[…]`, `chooser(…)` — and a
/// shape with no readable spelling is "this value" rather than a
/// phrase nobody typed.  Arena-owned with the walk.
fn calleeSpelling(self: *FunctionBuilder, callee: *const ast.Expression) Error![]const u8 {
    return (try placeSpelling(self, callee)) orelse "this value";
}

/// The written form of a place, or null where there is not one: an
/// index's subscript is elided and a call's arguments are, because
/// neither can be read back out of the tree and neither is what the
/// sentence is about.
fn placeSpelling(self: *FunctionBuilder, expression: *const ast.Expression) Error!?[]const u8 {
    return switch (expression.*) {
        .name => |name| name.text,
        .field => |field| blk: {
            const target = (try placeSpelling(self, field.target)) orelse break :blk null;
            break :blk try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ target, field.name });
        },
        .index => |index| blk: {
            const target = (try placeSpelling(self, index.target)) orelse break :blk null;
            break :blk try std.fmt.allocPrint(self.arena(), "{s}[…]", .{target});
        },
        .call => |call| try std.fmt.allocPrint(self.arena(), "{s}(…)", .{call.callee}),
        .value_call => |written| blk: {
            const target = (try placeSpelling(self, written.callee)) orelse break :blk null;
            break :blk try std.fmt.allocPrint(self.arena(), "{s}(…)", .{target});
        },
        .method => |method| blk: {
            const target = (try placeSpelling(self, method.target)) orelse break :blk null;
            break :blk try std.fmt.allocPrint(self.arena(), "{s}.{s}(…)", .{ target, method.name });
        },
        else => null,
    };
}

/// The local a reader would bind the value to, for the fix an absent
/// callee's refusal shows: the name it already has where it has one.
fn bindingName(callee: *const ast.Expression) []const u8 {
    return switch (callee.*) {
        .name => |name| name.text,
        .field => |field| field.name,
        else => "f",
    };
}

/// The one sentence a callee that **may hold none** gets, wherever it
/// was written (docs/BINDING.md D7).
///
/// A function value that may be absent is callable exactly where the
/// flow analysis has proved it is there, and only a local or a
/// parameter is ever proved: a field or an element can change between
/// the test and the use, so narrowing them would be a promise the
/// language cannot keep.  The fix is therefore always the same three
/// lines, and the refusal writes them out.
fn failAbsentCallee(
    self: *FunctionBuilder,
    written: []const u8,
    bound: []const u8,
    held: Type,
    span: Span,
) Error!void {
    try self.fail(
        "luce.sema.call",
        span,
        "{s} is {s} and may hold none; only a local or a parameter narrows, so bind it first " ++
            "(let {s} = {s}), test it (if {s} != none:), then call {s}(…)",
        .{ written, try self.analyzer.typeName(held), bound, written, bound, bound },
    );
}

/// `spawn f(args)` — the same call, made on a worker
/// (docs/THREADS.md D2, D3).
///
/// What may stand behind the keyword is a **function you declared**
/// and nothing else, and every refusal here is one sentence about
/// the same fact: a worker has a runtime of its own, so nothing it
/// is handed can be a borrow of anything here.
pub fn lowerSpawn(self: *FunctionBuilder, worker: ast.Spawn, as_statement: bool) Error!?Typed {
    const named: struct { index: u32, name: []const u8, arguments: []const ast.Argument } =
        switch (worker.call.*) {
            .call => |call| named: {
                // A builtin, a conversion or a construction is not
                // a declaration and has no frame to run in.
                const resolved = (try self.resolveDeclared(call.callee, call.span, call.origin)) orelse
                    return null;
                const index = self.analyzer.function_names.get(resolved) orelse {
                    try self.fail(
                        "luce.sema.call",
                        call.span,
                        "spawn runs a function you declared; {s} is not one",
                        .{call.callee},
                    );
                    return null;
                };
                break :named .{ .index = index, .name = call.callee, .arguments = call.arguments };
            },
            .method => |method| named: {
                switch (try methodNamespace(self, method)) {
                    .resolved => |resolved| {
                        if (self.analyzer.function_names.get(resolved)) |index| {
                            break :named .{
                                .index = index,
                                .name = resolved,
                                .arguments = method.arguments,
                            };
                        }
                        try self.fail(
                            "luce.sema.call",
                            method.span,
                            "spawn runs a function you declared; {s} is not one",
                            .{resolved},
                        );
                        return null;
                    },
                    else => {},
                }
                // A writing method aliases its receiver place in
                // *this* frame, so there is nothing a worker could
                // be given that would still be that place when it
                // finished.
                try self.fail(
                    "luce.sema.self",
                    method.span,
                    "a method's receiver is a place in this frame and a worker cannot reach it; " ++
                        "move the work into a function and spawn that",
                    .{},
                );
                return null;
            },
            // The parser admits nothing else in front of `spawn`.
            else => unreachable,
        };
    return lowerUserCall(
        self,
        named.index,
        named.name,
        named.arguments,
        worker.span,
        as_statement,
        false,
        .refused,
        worker.span,
    );
}

fn lowerUserCall(
    self: *FunctionBuilder,
    function_index: u32,
    name: []const u8,
    call_arguments: []const ast.Argument,
    span: Span,
    as_statement: bool,
    fallible_allowed: bool,
    shape_position: ShapePosition,
    /// Where the `spawn` keyword stands, when this call is one
    /// (docs/THREADS.md).  Null for an ordinary call, and the
    /// whole of what makes a spawn different: the arguments cross
    /// a runtime boundary, the answer is a `task` rather than the
    /// return type, and a fallible callee does not oblige *this*
    /// site to say `try` — the join does.
    spawning: ?Span,
) Error!?Typed {
    const info = self.analyzer.functions.items[function_index];
    if (!try refusals.functionReachable(self, function_index, span)) return null;
    if (info.is_entry) {
        try self.fail("luce.sema.call", span, "entry function {s} cannot be called", .{name});
        return null;
    }
    // A member is one of two things now: an implicit-self method,
    // called through a receiver, or `static`, called through its
    // type.  Keeping `Point.length(p)` would erase that distinction
    // and recreate the call-site ambiguity SELF removes.
    if (info.receiver != .not) {
        try self.fail(
            "luce.sema.self",
            span,
            "{s} is a method with implicit self; call it as {s}.{s}(…)",
            .{
                info.declaration.name,
                if (call_arguments.len != 0)
                    try writtenTarget(self, call_arguments[0].value)
                else
                    "the receiver",
                info.declaration.name,
            },
        );
        return null;
    }
    // See `callUser`: a call that can fail has to say which of
    // `try` and `catch` it means, and the check comes before the
    // arguments so the reader is told the one thing that matters.
    // A spawn is not the site that has to say `try`: nothing
    // fails here, and what the worker raises reaches the program
    // at `t.wait()`, which is where the words are (D4).
    if (info.fallible and !fallible_allowed and spawning == null) {
        try self.fail(
            "luce.sema.fallible",
            span,
            "{s} can fail: write 'try {s}(…)' to pass the error on, or '{s}(…) catch …' to handle it",
            .{ name, name, name },
        );
        return null;
    }
    if (spawning != null) {
        // A worker answers through its task, one value, once.  A
        // return shape has no `task[...]` spelling and would need
        // one before it could mean anything here.
        if (info.results.len >= 2) {
            try self.fail(
                "luce.sema.call",
                span,
                "{s} answers {d} values, and a task carries one; wrap them in a struct",
                .{ name, info.results.len },
            );
            return null;
        }
        // A function value borrows its receiver and never owns it
        // (docs/BINDING.md D4), and a borrow is exactly what cannot
        // cross — the sentence below about `give` says so for every
        // other carrying type.  The difference is that a function type
        // cannot say whether the value in front of it carries a
        // receiver at all, so the boundary cannot ask; it refuses the
        // type instead, which is the same conservatism the resource
        // checks either side of this one apply.
        //
        // **Through the whole type graph, since D7**: a function value
        // now sits in a struct field and a container element, and a
        // `list[(func() -> i64)?]` crossing would deep-copy every
        // receiver into the worker's runtime with nothing there owning
        // what it aliases.  The walk is the resource check's own.
        if (info.results.len == 1 and try shapes.carries(self.analyzer, info.return_type, .function)) {
            try self.fail(
                "luce.sema.own",
                span,
                "{s} answers {s}, which carries a function value, and a function value borrows the receiver it may carry; a borrow cannot cross back through wait, and a function type cannot say whether this one carries anything",
                .{ name, try self.analyzer.typeName(info.return_type) },
            );
            return null;
        }
        if (info.results.len == 1 and try shapes.carries(self.analyzer, info.return_type, .weak)) {
            try self.fail(
                "luce.sema.own",
                span,
                "{s} answers {s}, which contains a weak reference into the worker's private object table; a weak reference cannot cross back through wait",
                .{ name, try self.analyzer.typeName(info.return_type) },
            );
            return null;
        }
        // A borrow cannot cross a worker boundary: a function value
        // borrows the receiver it may carry, the type cannot say
        // whether a given value carries one, so the boundary refuses
        // the type outright (docs/THREADS.md D2, BINDING.md D4).
        for (info.parameter_types, info.declaration.parameters) |held, parameter| {
            if (try shapes.carries(self.analyzer, held, .function)) {
                try self.fail(
                    "luce.sema.own",
                    span,
                    "parameter {s} of {s} is {s}, which carries a function value, and a function value borrows the receiver it may carry; a borrow cannot cross a worker boundary, and a function type cannot say whether this one carries anything — name the function the worker should call instead",
                    .{ parameter.name, name, try self.analyzer.typeName(held) },
                );
                return null;
            }
            if (try shapes.carries(self.analyzer, held, .weak)) {
                try self.fail(
                    "luce.sema.own",
                    span,
                    "parameter {s} of {s} is {s}, which contains a weak reference into this runtime's object table; a weak reference cannot cross a worker boundary",
                    .{ parameter.name, name, try self.analyzer.typeName(held) },
                );
                return null;
            }
        }
    }
    // Which slot each argument fills is settled before any of them
    // is lowered: it is what says what type the argument lands in
    // (docs/ARGS.md §4) — the order `lowerConstruct` has kept
    // since construction shipped.
    const parameters = info.declaration.parameters;
    if (parameters.len != info.parameter_types.len) {
        // A parameter of this declaration failed to resolve, and
        // the declaration carries the diagnostic; there is no
        // signature left to check a call against.
        return null;
    }
    const surface = try declarationSlots(self, info);
    const seen = try self.temporary().alloc(bool, parameters.len);
    defer self.temporary().free(seen);
    @memset(seen, false);
    const slots = (try resolveSlots(self, name, "luce.sema.call", surface, 0, call_arguments, seen, span)) orelse
        return null;
    if (!(try checkRequiredSlots(self, name, "luce.sema.call", surface, seen, span))) return null;
    // Arguments are evaluated in the order they are written and
    // bound to the slots they name (D5): the batch runs in source
    // order, and only the destination index is permuted.
    const operand_expressions = try self.arena().alloc(*ast.Expression, call_arguments.len);
    const places = try self.arena().alloc(Type, call_arguments.len);
    for (call_arguments, operand_expressions, places, slots) |argument, *expression, *place, slot| {
        expression.* = argument.value;
        place.* = info.parameter_types[slot];
    }
    const run = (try self.lowerOperandsIntoTracking(operand_expressions, .{ .places = places })) orelse return null;
    const values = run.values;
    var defaulted: usize = 0;
    for (seen) |given| {
        if (!given) defaulted += 1;
    }
    const entries = try self.arena().alloc(RecordedOperand, values.len + defaulted);
    for (values, slots, 0..) |value, slot, index| {
        const fitted = (try self.fit(value, info.parameter_types[slot])) orelse {
            // A type mistake points at the argument, spelled the
            // way the reader spelled it: by name where it was
            // named, by position where it was counted.
            if (call_arguments[index].name) |written| {
                try self.fail("luce.sema.type", call_arguments[index].span, "{s} of {s} is {s}, got {s}{s}", .{
                    written,
                    name,
                    try self.analyzer.typeName(info.parameter_types[slot]),
                    try self.analyzer.typeName(value.value_type),
                    try refusals.mismatchAdvice(self, info.parameter_types[slot], value.value_type, operand_expressions[index]),
                });
            } else {
                try self.fail("luce.sema.type", call_arguments[index].span, "argument {d} of {s} is {s}, got {s}{s}", .{
                    slot + 1,
                    name,
                    try self.analyzer.typeName(info.parameter_types[slot]),
                    try self.analyzer.typeName(value.value_type),
                    try refusals.mismatchAdvice(self, info.parameter_types[slot], value.value_type, operand_expressions[index]),
                });
            }
            return null;
        };
        entries[index] = .{
            .node = fitted.node,
            .slot = slot,
            .copied = run.copied[index],
        };
    }
    // A slot nobody filled takes its default: the constant
    // register the same literal would have produced at the call
    // site (docs/ARGS.md D2) — no code path, no branch, no second
    // entry point.  A struct default owns the field run it just
    // made, so it is parked as the statement temporary a written
    // construction would be (S3).
    var next_entry = values.len;
    for (info.parameter_defaults, seen, 0..) |maybe_default, given, slot| {
        if (given) continue;
        const filled = maybe_default.?;
        const made = try expressions.emitConstantValue(self, filled.value, filled.value_type, span);
        try ledger.parkFreshStorage(self, made, span);
        entries[next_entry] = .{
            .node = made.node,
            .slot = @intCast(slot),
        };
        next_entry += 1;
    }
    // A spawn always answers something — the task — so the
    // "returns nothing" sentence is not about it.
    if (info.return_type == .none and !as_statement and spawning == null) {
        try self.fail("luce.sema.call", span, "{s} returns nothing", .{name});
        return null;
    }
    if (spawning) |_| {
        const carried = try resolve.internHeapType(self.analyzer, .{
            .task = .{ .result = info.return_type, .fallible = info.fallible },
        });
        // A spawn's node wraps the resolved call, and the inner
        // call's emission IS the spawn instruction — one
        // instruction carrying the callee and the batch, the task
        // as its result.  The call node keeps the callee's own
        // facts (its fallibility, its answer type), because the
        // join is where they surface (docs/THREADS.md D4).
        const inner = try recorder.recordCallNode(
            self,
            .{ .function = function_index },
            entries,
            values.len,
            info.fallible,
            info.return_type,
            span,
        );
        return .{
            .node = try recorder.recordNode(self, .{ .spawn = .{
                .call = inner,
                .result = carried,
                .span = span,
            } }),
            .value_type = carried,
        };
    }
    // A return shape is received by a destructuring let/var or
    // existing-name assignment, or discarded as a statement.  It
    // is not a tuple value that can stand in an argument, operand,
    // or direct return.
    if (info.results.len >= 2 and !as_statement and shape_position != .receive) {
        try self.fail(
            "luce.sema.call",
            span,
            "{s} answers {d} values, and only a destructuring let, var, or assignment can receive them{s}",
            .{
                name,
                info.results.len,
                if (shape_position == .returning) " — bind them, then return them" else "",
            },
        );
        return null;
    }
    const node = try recorder.recordCallNode(
        self,
        .{ .function = function_index },
        entries,
        values.len,
        info.fallible,
        info.return_type,
        span,
    );
    if (info.fallible) return try self.openFallible(info.return_type, node, span);
    // A function's result is the caller's (S16): fresh storage.
    return .{ .node = node, .value_type = info.return_type };
}

/// target.name(args): a namespaced call when the target chain is
/// bare declaration names (Struct.func, module.func,
/// module.Struct(...) construction), otherwise a builtin method on
/// the target value.  Locals shadow nothing, so a chain whose head
/// is a local is always a value method.
pub fn lowerMethod(
    self: *FunctionBuilder,
    method: ast.Method,
    as_statement: bool,
    fallible_allowed: bool,
    shape_position: ShapePosition,
) Error!?Typed {
    if (self.lifecycle == .initializer and builder.isBareSelf(method.target)) {
        // The initializer lifecycle validator already diagnosed the attempt
        // to call a method before the class identity exists.
        return null;
    }
    switch (try methodNamespace(self, method)) {
        .resolved => |resolved| {
            if (self.analyzer.alias_names.get(resolved)) |alias_index| {
                const call: ast.Call = .{
                    .callee = method.name,
                    .arguments = method.arguments,
                    .span = method.span,
                };
                return lowerAliasCall(self, call, alias_index, as_statement, fallible_allowed, shape_position);
            }
            if (self.analyzer.struct_names.get(resolved)) |layout_index| {
                return lowerNominalConstruct(
                    self,
                    layout_index,
                    method.name,
                    method.arguments,
                    method.span,
                    as_statement,
                    fallible_allowed,
                    shape_position,
                );
            }
            if (self.analyzer.interface_names.get(resolved)) |interface_index| {
                return construct.lowerConstruct(
                    self,
                    method.arguments,
                    method.span,
                    self.analyzer.interface_decls.items[interface_index].layout,
                );
            }
            if (self.analyzer.enum_names.get(resolved)) |enum_index| {
                return construct.lowerEnumOfNumber(self, method.name, method.arguments, method.span, enum_index);
            }
            if (self.analyzer.variant_names.get(resolved)) |variant_index| {
                return construct.failVariantAsCallee(self, method.name, variant_index, method.span);
            }
            // `Shape.circle(radius = 2.0)` — a union member, which
            // is the one construction a union has (docs/UNION.md
            // D4).  Asked before the function table because the
            // two cannot collide: a member and a function sharing
            // a name is refused where the union is declared.
            if (construct.variantMemberOfQualified(self, resolved)) |found| {
                return construct.lowerVariantConstruct(
                    self,
                    method.arguments,
                    method.span,
                    found.variant,
                    found.member,
                );
            }
            const function_index = self.analyzer.function_names.get(resolved).?;
            return lowerUserCall(
                self,
                function_index,
                resolved,
                method.arguments,
                method.span,
                as_statement,
                fallible_allowed,
                shape_position,
                null,
            );
        },
        .reported => return null,
        .value => return lowerValueMethod(self, method, as_statement, fallible_allowed, shape_position),
    }
}

/// Build a nominal value. Classes with `init` route through their hidden
/// factory function; every other class and every struct keeps the direct
/// memberwise construction path. This is the one fork shared by bare,
/// imported, and aliased type names.
fn lowerNominalConstruct(
    self: *FunctionBuilder,
    layout: u32,
    written_name: []const u8,
    arguments: []const ast.Argument,
    span: Span,
    as_statement: bool,
    fallible_allowed: bool,
    shape_position: ShapePosition,
) Error!?Typed {
    if (self.analyzer.struct_decls.items[layout].initializer) |initializer| {
        return lowerUserCall(
            self,
            initializer,
            written_name,
            arguments,
            span,
            as_statement,
            fallible_allowed,
            shape_position,
            null,
        );
    }
    return construct.lowerConstruct(self, arguments, span, layout);
}

/// A type alias in a call-shaped expression. Nominal construction and enum
/// lookup use the original declaration table; scalar aliases use the same
/// conversion lowering as their target. Every other type remains a type, not
/// a callable value, and receives a direct diagnostic.
fn lowerAliasCall(
    self: *FunctionBuilder,
    call: ast.Call,
    alias_index: u32,
    as_statement: bool,
    fallible_allowed: bool,
    shape_position: ShapePosition,
) Error!?Typed {
    const target = (try resolve.resolveAlias(self.analyzer, self.module, alias_index, call.span)) orelse
        return null;
    return switch (target) {
        .strukt => |layout| lowerNominalConstruct(
            self,
            layout,
            call.callee,
            call.arguments,
            call.span,
            as_statement,
            fallible_allowed,
            shape_position,
        ),
        .enumeration => |reference| construct.lowerEnumOfNumber(
            self,
            call.callee,
            call.arguments,
            call.span,
            reference.index,
        ),
        .variant => |index| construct.failVariantAsCallee(self, call.callee, index, call.span),
        .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f16, .f32, .f64, .char, .str, .bytes => construct.lowerAliasConvert(self, call, target),
        else => {
            const declaration = self.analyzer.alias_decls.items[alias_index].declaration;
            if (target == .heap) {
                const heap = self.analyzer.heapOf(target).?;
                switch (heap) {
                    .class => |layout| return lowerNominalConstruct(
                        self,
                        layout,
                        call.callee,
                        call.arguments,
                        call.span,
                        as_statement,
                        fallible_allowed,
                        shape_position,
                    ),
                    .list, .map, .array, .builder => {
                        try self.fail(
                            "luce.sema.call",
                            call.span,
                            "{s} is a type alias for {s}, not a callable value; construct it with new {s}",
                            .{ declaration.name, try self.analyzer.typeName(target), declaration.name },
                        );
                    },
                    .file => try self.fail(
                        "luce.sema.call",
                        call.span,
                        "{s} is a type alias for file, not a callable value; open a file through std.files",
                        .{declaration.name},
                    ),
                    .task => try self.fail(
                        "luce.sema.call",
                        call.span,
                        "{s} is a type alias for {s}, not a callable value; spawn a function to create a task",
                        .{ declaration.name, try self.analyzer.typeName(target) },
                    ),
                }
                return null;
            }
            try self.fail(
                "luce.sema.call",
                call.span,
                "{s} is a type alias for {s}, not a callable value",
                .{
                    declaration.name,
                    try self.analyzer.typeName(target),
                },
            );
            return null;
        },
    };
}

const NamespaceResolution = union(enum) {
    /// Not a namespace: lower as a method on a value.
    value,
    /// A namespace whose member is missing; already diagnosed.
    reported,
    /// The fully-qualified declaration this call names.
    resolved: []const u8,
};

/// A dotted chain of bare names in front of a call, collected
/// inner-to-outer: for geo.Text.width(...) the parts are
/// [width-side first] and the head is "geo".
/// Decide whether target.name(...) names a declaration.
fn methodNamespace(self: *FunctionBuilder, method: ast.Method) Error!NamespaceResolution {
    const chain = helpers.dottedChain(method.target) orelse return .value;
    const parts = chain.parts;
    const count = chain.count;
    const head = chain.head();
    if (self.findLocal(head) != null) return .value;
    if (try refusals.failCapturedName(self, head, method.span)) return .reported;

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
    // `Method.stored.compressed()` — the chain in front of the call
    // names a *member*, which is a value, so this is a method on
    // one and not a namespace path (docs/ENUMS.md D3).  The same
    // shape as the imported-constant case below, one enum earlier.
    if (chain.count >= 2 and self.namesMember(parts[0..chain.count])) return .value;

    // `Alias.member(...)` and `module.Alias.member(...)` use the
    // declaration namespace of the alias target.  The alias itself never
    // owns copied static/member declarations; rewriting the namespace here
    // keeps one authoritative function/member table.
    const namespace_written = joined[0 .. joined.len - method.name.len - 1];
    const alias_key: ?[]const u8 = if (count == 1)
        try naming.qualify(self.analyzer, self.prefix, namespace_written)
    else if (naming.importsModule(self.analyzer, self.module, head))
        try self.importedName(namespace_written)
    else
        null;
    if (alias_key) |key| {
        if (self.analyzer.alias_names.get(key)) |alias_index| {
            const target = (try resolve.resolveAlias(self.analyzer, self.module, alias_index, method.span)) orelse
                return .reported;
            const canonical = resolve.namespaceName(self.analyzer, target) orelse {
                try self.fail(
                    "luce.sema.call",
                    method.span,
                    "{s} is a type alias for {s}, which has no static members",
                    .{ namespace_written, try self.analyzer.typeName(target) },
                );
                return .reported;
            };
            const member = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ canonical, method.name });
            if (isNamespaceDeclaration(self, member)) {
                return .{ .resolved = member };
            }
            try refusals.failNamespaceMember(self, namespace_written, method.name, member, method.span);
            return .reported;
        }
    }

    const head_qualified = try naming.qualify(self.analyzer, self.prefix, head);
    if (self.analyzer.struct_names.contains(head_qualified) or
        self.analyzer.interface_names.contains(head_qualified) or
        self.analyzer.enum_names.contains(head_qualified) or
        self.analyzer.variant_names.contains(head_qualified))
    {
        const local = try naming.qualify(self.analyzer, self.prefix, joined);
        if (self.analyzer.struct_names.contains(local) or
            self.analyzer.interface_names.contains(local) or
            self.analyzer.enum_names.contains(local) or
            self.analyzer.variant_names.contains(local) or
            self.analyzer.function_names.contains(local) or
            construct.variantMemberOfQualified(self, local) != null)
        {
            return .{ .resolved = try self.arena().dupe(u8, local) };
        }
        try refusals.failUnknownFunction(self, joined, method.span);
        return .reported;
    }
    if (naming.importsModule(self.analyzer, self.module, head)) {
        const key = try self.importedName(joined);
        if (self.analyzer.struct_names.contains(key) or
            self.analyzer.interface_names.contains(key) or
            self.analyzer.enum_names.contains(key) or
            self.analyzer.variant_names.contains(key) or
            self.analyzer.alias_names.contains(key) or
            self.analyzer.function_names.contains(key) or
            construct.variantMemberOfQualified(self, key) != null)
        {
            return .{ .resolved = try self.arena().dupe(u8, key) };
        }
        // geo.pi.method() — a value method on an imported constant.
        if (count >= 2) {
            const member = try std.fmt.allocPrint(self.temporary(), "{s}.{s}", .{ head, parts[count - 2] });
            defer self.temporary().free(member);
            if (self.analyzer.constant_names.contains(try self.importedName(member))) return .value;
        }
        try refusals.failUnknownFunction(self, joined, method.span);
        return .reported;
    }
    // The head names a module elsewhere in this program: point at
    // the missing import instead of "unknown name".  Value reads use
    // the same refusal in expressions.zig.
    if (try refusals.failUnimportedNamespace(self, head, method.span)) return .reported;
    return .value;
}

fn isNamespaceDeclaration(self: *FunctionBuilder, qualified: []const u8) bool {
    return self.analyzer.struct_names.contains(qualified) or
        self.analyzer.interface_names.contains(qualified) or
        self.analyzer.enum_names.contains(qualified) or
        self.analyzer.variant_names.contains(qualified) or
        self.analyzer.alias_names.contains(qualified) or
        self.analyzer.function_names.contains(qualified) or
        construct.variantMemberOfQualified(self, qualified) != null;
}

/// Builtin methods on values: strings, lists, arrays, maps, and
/// builders.  `x.f(y)` is sugar for a plain typed operation with
/// the receiver first — there is no dispatch.
fn lowerValueMethod(
    self: *FunctionBuilder,
    method: ast.Method,
    as_statement: bool,
    fallible_allowed: bool,
    shape_position: ShapePosition,
) Error!?Typed {
    const operand_expressions = try self.arena().alloc(*ast.Expression, method.arguments.len + 1);
    operand_expressions[0] = method.target;
    for (method.arguments, 0..) |argument, index| {
        operand_expressions[index + 1] = argument.value;
    }
    const run = (try self.lowerOperandsIntoTracking(operand_expressions, .{ .method = method })) orelse return null;
    const values = run.values;
    const receiver = values[0];
    const arguments = values[1..];
    if (try refusals.refusesAbsence(self, receiver, "a method's receiver", method.span, method.target)) {
        return null;
    }

    // Interface values expose only their contract methods.  Their hidden
    // function fields never enter ordinary field lookup; this path builds a
    // field-get plus indirect call instead.
    if (receiver.value_type == .strukt) {
        if (self.analyzer.interfaceForLayout(receiver.value_type.strukt)) |interface_index| {
            return lowerInterfaceCall(self, method, run, as_statement, fallible_allowed, shape_position, interface_index);
        }
    }

    // A class has declared methods but still lives in the heap-type table.
    // Route it before builtin object dispatch: its identity is the implicit
    // receiver of an ordinary declared call, not a container descriptor.
    if (self.analyzer.classLayout(receiver.value_type) != null) {
        return lowerReceiverCall(
            self,
            method,
            run,
            as_statement,
            fallible_allowed,
            shape_position,
        );
    }

    const found: MethodFound = blk: {
        if (receiver.value_type == .str) {
            // The primitives above, and nothing else: every other
            // string method is library code — s.find(x) is
            // strings.find(s, x) (docs/STD.md).
            for (string_methods) |primitive| {
                if (!std.mem.eql(u8, method.name, primitive.name)) continue;
                if (try refuseNamedMethodArguments(self, method)) return null;
                if (!try methodTakes(self, method, arguments, receiver.value_type)) return null;
                break :blk .{ .kind = primitive.kind, .result = primitive.result };
            }
            return stringsCall(self, method, run, as_statement);
        }
        if (self.analyzer.heapOf(receiver.value_type)) |descriptor| {
            // join belongs to the strings module too: it makes a
            // string, from list[str].
            if (descriptor == .list and descriptor.list == .str and
                std.mem.eql(u8, method.name, "join"))
            {
                return stringsCall(self, method, run, as_statement);
            }
            // Comparator sorting is ordinary std Luce, routed from
            // list method sugar and specialized at the receiver's
            // monomorphic element type (FUNCTIONS.md D6).
            if (descriptor == .list and std.mem.eql(u8, method.name, "sort_by")) {
                return listsCall(self, method, run, descriptor.list, as_statement);
            }
            if (try refuseNamedMethodArguments(self, method)) return null;
            if (try objectMethod(self, method, receiver.value_type, descriptor, arguments)) |found| {
                break :blk found;
            }
            return null;
        }
        // A declared value: `p.length()` resolves the non-static
        // member belonging to `p`'s type.  SELF deliberately
        // reserves `Point.length(...)` for static members; readers
        // lower to an ordinary direct call and writers to the
        // inout call that aliases `p`'s binding.
        //
        // It can never race a built-in method, and by construction
        // rather than by ordering: `types.StructLayout` has no
        // functions field and `heapOf` answers null for a struct,
        // so the two arms above are unreachable for one.
        // An enum answers here too, and by the same rule: its
        // functions are declared inside it and named `Method.f`, so
        // `m.compressed()` resolves its non-static member by the
        // same lookup (docs/ENUMS.md D7, docs/SELF.md D1-D2).
        if (declaredName(self, receiver.value_type) != null) {
            return lowerReceiverCall(
                self,
                method,
                run,
                as_statement,
                fallible_allowed,
                shape_position,
            );
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
    // A list keeps what it is appended, so the element is a store
    // and takes or copies its storage; a builder copies bytes
    // into a buffer of its own and borrows (docs/STRINGS.md).
    // That take-or-copy is a *store* decision the batch does not
    // flag: it is the ledger's answer (coupling #3), decided by
    // the same ledger walk lower replays.
    if (storedElement(self, found.kind, receiver.value_type)) |position| {
        ledger.ownedForStore(self, values[position]);
    }
    // The receiver is operand zero of its own batch, so the node's
    // operand run is the whole of `values`, positionally.
    const entries = try self.arena().alloc(RecordedOperand, values.len);
    for (values, entries, 0..) |value, *entry, index| {
        entry.* = .{
            .node = value.node,
            .slot = @intCast(index),
            .copied = run.copied[index],
        };
    }
    // A method can fail too, since the byte channel arrived: a
    // handle's read, write and flush all answer to the world
    // (docs/BYTES.md).  Same rule as a free builtin's — the call
    // site says which of `try` and `catch` it means, and a site
    // that says neither is `luce.sema.fallible` rather than a
    // silently dropped outcome (docs/FAILURE.md).
    // `wait` is the one whose fallibility is not a fact about the
    // method: it comes back errored exactly when the function the
    // task carries could, so the answer is read off the receiver's
    // own shape (docs/THREADS.md D4).
    const may_fail = if (found.kind == .task_wait)
        taskShape(self, receiver.value_type).?.fallible
    else
        found.kind.isFallible();
    const node = try recorder.recordCallNode(
        self,
        .{ .intrinsic = found.kind },
        entries,
        values.len,
        may_fail,
        found.result,
        method.span,
    );
    if (may_fail) {
        if (!fallible_allowed) {
            try self.fail(
                "luce.sema.fallible",
                method.span,
                "{s} can fail: write 'try x.{s}(…)' to pass the error on, or 'x.{s}(…) catch …' to handle it",
                .{ method.name, method.name, method.name },
            );
            return null;
        }
        return try self.openFallible(found.result, node, method.span);
    }
    return .{ .node = node, .value_type = found.result };
}

fn methodWritesReceiver(kind: mir.Intrinsic) bool {
    return switch (kind) {
        .append_value,
        .append_ascii,
        .insert_value,
        .remove_entry,
        .pop_value,
        .clear_object,
        .array_fill,
        .list_sort,
        .list_reverse,
        => true,
        else => false,
    };
}

// Methods on a struct value ---------------------------------------------
//
// `p.length()` resolves a non-static member from `p`'s declared
// type.  There is no dispatch or bound reference: stage 4 emits a
// direct read call or an inout writing call (docs/SELF.md).

/// The declaration behind `x.f(…)` on a struct value, silently:
/// the function `Struct.f` when it is a *method*, null when there
/// is no such name or the name is a namespace function — whose
/// receiver is not parameter zero, and whose method-form call
/// `lowerReceiverCall` refuses with the sentence that says so.
///
/// `landsOn` asks this mid-batch, before an argument is lowered, so
/// every explicit argument lands on the declared slot after hidden
/// self.  Literals and `none` therefore receive the same context as
/// an ordinary declared-function argument (docs/ARGS.md §4).
pub fn structMethod(self: *FunctionBuilder, receiver: Type, name: []const u8) Error!?u32 {
    const declared = declaredName(self, receiver) orelse return null;
    const qualified = try std.fmt.allocPrint(self.temporary(), "{s}.{s}", .{ declared, name });
    defer self.temporary().free(qualified);
    const function_index = self.analyzer.function_names.get(qualified) orelse return null;
    if (self.analyzer.functions.items[function_index].receiver == .not) return null;
    return function_index;
}

/// The qualified name of the declaration a value's type came from —
/// `Point`, `geo.Method` — or null for a type nobody declared.
///
/// **The two declaration keywords answer here alike.**  A struct and
/// an enum both spell their functions `Name.func`, so the whole of
/// the method machinery needs the name and nothing else
/// (docs/SELF.md, docs/ENUMS.md D7); only a sentence that has to
/// say which word was written looks further.
pub fn declaredName(self: *const FunctionBuilder, of: Type) ?[]const u8 {
    return switch (of) {
        .strukt => |index| self.analyzer.structs.items[index].name,
        .heap => if (self.analyzer.classLayout(of)) |index|
            self.analyzer.structs.items[index].name
        else
            null,
        .enumeration => |reference| self.analyzer.enums.items[reference.index].name,
        .variant => |index| self.analyzer.variants.items[index].name,
        else => null,
    };
}

/// `element.method(args)` where `element` is an interface value.  The
/// receiver is already bound in the function slot stored by `interface_make`;
/// the call therefore passes only the explicit arguments to `call_indirect`.
fn lowerInterfaceCall(
    self: *FunctionBuilder,
    method: ast.Method,
    run: OperandRun,
    as_statement: bool,
    fallible_allowed: bool,
    shape_position: ShapePosition,
    interface_index: u32,
) Error!?Typed {
    const contract = self.analyzer.interface_decls.items[interface_index];
    var selected: ?context.InterfaceMethodInfo = null;
    for (contract.methods) |candidate| {
        if (std.mem.eql(u8, candidate.declaration.name, method.name)) {
            selected = candidate;
            break;
        }
    }
    const info = selected orelse {
        try self.fail("luce.sema.method", method.span, "interface {s} has no method {s}", .{
            contract.declaration.name,
            method.name,
        });
        return null;
    };
    if (info.fallible and !fallible_allowed) {
        try self.fail(
            "luce.sema.fallible",
            method.span,
            "{s} can fail: write 'try {s}.{s}(…)' to pass the error on, or '{s}.{s}(…) catch …' to handle it",
            .{ method.name, try writtenReceiver(self, method), method.name, try writtenReceiver(self, method), method.name },
        );
        return null;
    }

    const surface = try self.arena().alloc(CallSlot, info.parameter_types.len);
    for (info.declaration.parameters, surface) |parameter, *slot| {
        slot.* = .{ .name = parameter.name };
    }
    const seen = try self.temporary().alloc(bool, surface.len);
    defer self.temporary().free(seen);
    @memset(seen, false);
    const slots = (try resolveSlots(self, method.name, "luce.sema.method", surface, 0, method.arguments, seen, method.span)) orelse
        return null;
    if (!(try checkRequiredSlots(self, method.name, "luce.sema.method", surface, seen, method.span))) return null;

    const entries = try self.arena().alloc(RecordedOperand, run.values.len - 1);
    for (method.arguments, slots, 0..) |argument, slot, index| {
        const value = run.values[index + 1];
        const fitted = (try self.fit(value, info.parameter_types[slot])) orelse {
            try self.fail("luce.sema.type", argument.span, "argument {d} of {s} is {s}, got {s}{s}", .{
                index + 1,
                method.name,
                try self.analyzer.typeName(info.parameter_types[slot]),
                try self.analyzer.typeName(value.value_type),
                try refusals.absenceAdvice(self, value.value_type, argument.value),
            });
            return null;
        };
        entries[index] = .{
            .node = fitted.node,
            .slot = slot,
            .copied = run.copied[index + 1],
        };
    }
    if (info.return_type == .none and !as_statement) {
        try self.fail("luce.sema.call", method.span, "{s} returns nothing", .{method.name});
        return null;
    }
    if (info.results.len >= 2 and !as_statement and shape_position != .receive) {
        try self.fail(
            "luce.sema.call",
            method.span,
            "{s} answers {d} values, and only a destructuring let, var, or assignment can receive them",
            .{ method.name, info.results.len },
        );
        return null;
    }
    const receiver = run.values[0];
    const callee = try self.arena().create(nodes.Expression);
    callee.* = .{ .field_get = .{
        .target = receiver.node,
        .layout = receiver.value_type.strukt,
        .field = info.field,
        .result = .{ .function = info.signature },
        .span = method.span,
    } };
    const node = try recorder.recordCallNode(
        self,
        .{ .indirect = .{
            .callee = callee,
            .signature = info.signature,
            .fallible = info.fallible,
        } },
        entries,
        entries.len,
        info.fallible,
        info.return_type,
        method.span,
    );
    if (info.fallible) return try self.openFallible(info.return_type, node, method.span);
    return .{ .node = node, .value_type = info.return_type };
}

/// `x.f(a, b)` where `x` is a value of a declared type — a struct
/// or an enum.  `run` is the whole operand batch with the receiver
/// at zero, already lowered by `lowerValueMethod`; a method's
/// arguments take their types from the values, exactly as every
/// other method's do.
fn lowerReceiverCall(
    self: *FunctionBuilder,
    method: ast.Method,
    run: OperandRun,
    as_statement: bool,
    fallible_allowed: bool,
    shape_position: ShapePosition,
) Error!?Typed {
    const values = run.values;
    const receiver_type = values[0].value_type;
    const declared = declaredName(self, receiver_type).?;
    const qualified = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ declared, method.name });
    const function_index = self.analyzer.function_names.get(qualified) orelse {
        try failUnknownMethod(self, receiver_type, declared, method);
        return null;
    };
    if (!try refusals.functionReachable(self, function_index, method.span)) return null;
    const info = self.analyzer.functions.items[function_index];
    // `static` is the whole difference between a namespace member
    // and a method, and this is where the wrong call spelling
    // teaches it (docs/SELF.md D1-D2).
    if (info.receiver == .not) {
        try self.fail(
            "luce.sema.self",
            method.span,
            "{s} is static and has no self; call it as {s}(…)",
            .{ method.name, qualified },
        );
        return null;
    }
    if (info.fallible and !fallible_allowed) {
        try self.fail(
            "luce.sema.fallible",
            method.span,
            "{s} can fail: write 'try {s}.{s}(…)' to pass the error on, or '{s}.{s}(…) catch …' to handle it",
            .{
                method.name,
                try writtenReceiver(self, method),
                method.name,
                try writtenReceiver(self, method),
                method.name,
            },
        );
        return null;
    }

    // Which slot each argument fills: the receiver is parameter
    // zero and stands in front of the dot, so the call site writes
    // slots one up — the `hidden = 1` case of the one resolver
    // every user-call spelling shares (docs/ARGS.md §4).
    const parameters = info.declaration.parameters;
    if (parameters.len + 1 != info.parameter_types.len) {
        // A parameter of this declaration failed to resolve, and
        // the declaration carries the diagnostic.
        return null;
    }
    const surface = try declarationSlots(self, info);
    const seen = try self.temporary().alloc(bool, info.parameter_types.len);
    defer self.temporary().free(seen);
    @memset(seen, false);
    seen[0] = true; // the receiver, already in hand
    const slots = (try resolveSlots(self, method.name, "luce.sema.method", surface, 1, method.arguments, seen, method.span)) orelse
        return null;
    if (!(try checkRequiredSlots(self, method.name, "luce.sema.method", surface, seen, method.span))) return null;

    // The inout call carries the receiver's *place* separately;
    // its argument run contains only the values written between
    // parentheses.  A read method remains an ordinary call with
    // the receiver value at logical parameter zero.  The recorded
    // batch keeps the receiver at slot 0 either way — the tree
    // says what was written, and which emission drops the
    // receiver register is the callee's own fact.
    var defaulted: usize = 0;
    for (seen) |given| {
        if (!given) defaulted += 1;
    }
    const entries = try self.arena().alloc(RecordedOperand, values.len + defaulted);
    entries[0] = .{
        .node = values[0].node,
        .slot = 0,
        .copied = run.copied[0],
    };
    for (method.arguments, slots, 0..) |argument, slot, index| {
        const value = values[index + 1];
        const want = info.parameter_types[slot];
        const fitted = (try self.fit(value, want)) orelse {
            if (argument.name) |written| {
                try self.fail("luce.sema.type", argument.span, "{s} of {s} is {s}, got {s}{s}", .{
                    written,
                    method.name,
                    try self.analyzer.typeName(want),
                    try self.analyzer.typeName(value.value_type),
                    try refusals.absenceAdvice(self, value.value_type, argument.value),
                });
            } else {
                try self.fail("luce.sema.type", argument.span, "argument {d} of {s} is {s}, got {s}{s}", .{
                    slot,
                    method.name,
                    try self.analyzer.typeName(want),
                    try self.analyzer.typeName(value.value_type),
                    try refusals.absenceAdvice(self, value.value_type, argument.value),
                });
            }
            return null;
        };
        // A writing method may replace its receiver while this
        // ordinary argument is still live in the callee.  If the
        // argument borrows string or struct storage from that
        // receiver (`s.change(s)` or `s.change(s.text)`), passing
        // the view would leave the parameter pointing at freed
        // bytes.  Keep a caller-owned storage copy through the
        // call.  Objects inside a copied struct intentionally stay
        // aliases: D6 keeps ordinary object borrowing unchanged.
        // The keep-copy is deliberately not a batch flag: it
        // follows from the resolved callee — receiver mode and
        // parameter type — so lower re-derives it
        // (nodes.OperandBatch).
        if (info.receiver == .writes and shapes.ownsStorage(self.analyzer, want)) {
            // The keep-copy is storage nobody owns yet, parked as
            // a derived temporary — the second of the two parks
            // the recording never sees, re-derived by lower from
            // the resolved callee (nodes.OperandBatch).
            _ = try ledger.parkDerivedTemp(self, want, method.span);
        }
        entries[index + 1] = .{
            .node = fitted.node,
            .slot = slot,
            .copied = run.copied[index + 1],
        };
    }
    // A slot nobody filled takes its default (docs/ARGS.md D2),
    // parked like the written construction it stands in for (S3).
    var next_entry = values.len;
    for (info.parameter_defaults, seen, 0..) |maybe_default, given, slot| {
        if (given) continue;
        const filled = maybe_default.?;
        const made = try expressions.emitConstantValue(self, filled.value, filled.value_type, method.span);
        try ledger.parkFreshStorage(self, made, method.span);
        entries[next_entry] = .{
            .node = made.node,
            .slot = @intCast(slot),
        };
        next_entry += 1;
    }
    if (info.results.len == 0 and !as_statement) {
        try self.fail("luce.sema.call", method.span, "{s} returns nothing", .{method.name});
        return null;
    }
    if (info.results.len >= 2 and !as_statement and shape_position != .receive) {
        try self.fail(
            "luce.sema.call",
            method.span,
            "{s} answers {d} values, and only a destructuring let, var, or assignment can receive them{s}",
            .{
                method.name,
                info.results.len,
                if (shape_position == .returning) " — bind them, then return them" else "",
            },
        );
        return null;
    }
    if (info.receiver == .writes) {
        _ = (try receiverPlace(self, method, info.parameter_types[0])) orelse return null;
    }
    const node = try recorder.recordCallNode(
        self,
        .{ .function = function_index },
        entries,
        values.len,
        info.fallible,
        info.return_type,
        method.span,
    );
    const answered: Typed = if (info.fallible)
        try self.openFallible(info.return_type, node, method.span)
    else
        // A function's result is the caller's (S16): fresh storage.
        .{ .node = node, .value_type = info.return_type };
    return answered;
}

/// The caller-owned slot a writing method receives in place.  The
/// current SELF surface deliberately admits bare mutable bindings;
/// read methods still accept arbitrary values and temporaries.
fn receiverPlace(
    self: *FunctionBuilder,
    method: ast.Method,
    receiver_type: Type,
) Error!?LocalId {
    switch (method.target.*) {
        .name => |name| {
            const found = self.findLocal(name.text) orelse {
                const qualified = try naming.qualify(self.analyzer, self.prefix, name.text);
                if (self.analyzer.constant_names.contains(qualified)) {
                    try self.fail(
                        "luce.sema.const",
                        name.span,
                        "{s} is a file-scope constant; {s} writes its implicit self — assign it to a var first",
                        .{ name.text, method.name },
                    );
                } else {
                    try refusals.failUnknownName(self, name.text, name.span);
                }
                return null;
            };
            if (!found.info.mutable) {
                try self.fail(
                    "luce.sema.let",
                    name.span,
                    "{s} is let-bound; {s} writes its implicit self — use var",
                    .{ name.text, method.name },
                );
                return null;
            }
            const place_type = recorder.localType(self, found.info.local);
            if (!place_type.eql(receiver_type)) {
                try self.fail(
                    "luce.sema.self",
                    name.span,
                    "{s} is {s}; {s} writes a {s} in place, so a narrowed value is not a writable receiver — bind a var {s} first",
                    .{
                        name.text,
                        try self.analyzer.typeName(place_type),
                        method.name,
                        try self.analyzer.typeName(receiver_type),
                        try self.analyzer.typeName(receiver_type),
                    },
                );
                return null;
            }
            if (found.info.iterating) {
                try self.fail(
                    "luce.sema.own",
                    name.span,
                    "{s} is being iterated; a writing method would change it under the loop",
                    .{name.text},
                );
                return null;
            }
            return found.info.local;
        },
        else => {
            try self.fail(
                "luce.sema.self",
                method.span,
                "{s} writes its implicit self, so its receiver must be a var binding — not a call result or temporary",
                .{method.name},
            );
            return null;
        },
    }
}

/// How the reader spelled the receiver for a method diagnostic:
/// the bare name where there is one, and a neutral phrase for an
/// expression nobody named.
fn writtenReceiver(self: *FunctionBuilder, method: ast.Method) Error![]const u8 {
    return writtenTarget(self, method.target);
}

pub fn writtenTarget(self: *FunctionBuilder, target: *const ast.Expression) Error![]const u8 {
    _ = self;
    return switch (target.*) {
        .name => |name| name.text,
        else => "the receiver",
    };
}

/// `p.foo()` where `Point` has no `foo` at all.
///
/// **This replaces "Point has no methods"**, which was true until
/// a struct could have one and would now be a lie.  It offers the
/// closest method there actually is, which is what the list, map
/// and builder families already do.
fn failUnknownMethod(
    self: *FunctionBuilder,
    receiver: Type,
    written_name: []const u8,
    method: ast.Method,
) Error!void {
    if (try failFieldIsNotAMethod(self, receiver, method)) return;
    var suggestion = helpers.Suggestion.init(method.name);
    for (self.analyzer.functions.items) |candidate| {
        const owner = candidate.enclosing orelse continue;
        if (!owner.asType().eql(receiver)) continue;
        if (candidate.receiver == .not) continue;
        // Never a method this module cannot call (VISIBILITY.md D2).
        if (candidate.declaration.visibility == .private and candidate.module != self.module) continue;
        const dot = std.mem.lastIndexOfScalar(u8, candidate.name, '.') orelse continue;
        suggestion.offer(candidate.name[dot + 1 ..]);
    }
    if (suggestion.best()) |closest| {
        try self.fail("luce.sema.method", method.span, "{s} has no method {s}; did you mean {s}?", .{
            written_name, method.name, closest,
        });
        return;
    }
    try self.fail("luce.sema.method", method.span, "{s} has no method {s}", .{ written_name, method.name });
}

/// `r.render(3)` where `render` is a **field** holding a function
/// value, not a method (docs/BINDING.md D7).
///
/// The two read alike, so "Rows has no method render" sends the reader
/// looking for a declaration that was never the point.  True when it
/// reported; false leaves the ordinary did-you-mean to answer.
fn failFieldIsNotAMethod(
    self: *FunctionBuilder,
    receiver: Type,
    method: ast.Method,
) Error!bool {
    const layout_index = self.analyzer.nominalLayout(receiver) orelse return false;
    const layout = self.analyzer.structs.items[layout_index];
    const field_index = layout.findField(method.name) orelse return false;
    const field_type = layout.fields[field_index].field_type;
    const holds_function = field_type == .function or
        (field_type == .optional and field_type.optional == .function);
    if (!holds_function) return false;
    // A field this module cannot see is answered as private, never as
    // a fix it could not take (VISIBILITY.md D2).
    if (!try refusals.fieldReachable(self, layout_index, field_index, method.span)) return true;
    const written = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{
        try writtenReceiver(self, method),
        method.name,
    });
    if (field_type == .function) {
        try self.fail(
            "luce.sema.call",
            method.span,
            "{s} is a field holding {s}, not a method; call the value it holds: ({s})(…)",
            .{ written, try self.analyzer.typeName(field_type), written },
        );
        return true;
    }
    try failAbsentCallee(self, written, method.name, field_type, method.span);
    return true;
}

/// Which argument of a method is a *store* into the receiver —
/// the one `libluce_rt` will keep rather than read.  The positions
/// are `Intrinsic.storedArgument`'s; this adds the receiver's
/// shape, which is what says a list is being appended to and not a
/// builder of the same spelling.
fn storedElement(self: *const FunctionBuilder, kind: mir.Intrinsic, receiver: Type) ?usize {
    const descriptor = self.analyzer.heapOf(receiver) orelse return null;
    if (descriptor != .list) return null;
    return kind.storedArgument();
}

/// A builtin method's arguments are positional (docs/ARGS.md D10):
/// its tables hold types computed from the receiver and no names,
/// and a parallel name list would be exactly the drift the
/// one-table comment on `builtins` records.  True after reporting.
fn refuseNamedMethodArguments(self: *FunctionBuilder, method: ast.Method) Error!bool {
    for (method.arguments) |argument| {
        if (argument.name == null) continue;
        try self.fail(
            "luce.sema.method",
            argument.span,
            "{s} is a builtin method and its arguments are positional",
            .{method.name},
        );
        return true;
    }
    return false;
}

const MethodFound = struct { kind: mir.Intrinsic, result: Type };

fn methodFail(self: *FunctionBuilder, method: ast.Method, comptime message: []const u8) Error!?MethodFound {
    try self.fail("luce.sema.method", method.span, message, .{});
    return null;
}

/// Check a built-in method's arguments against the types it takes,
/// and say the one thing that is wrong.
///
/// This is the sentence `lowerUserCall` writes for a user
/// function, and a built-in method had better earn the same one:
/// the count sentence names both counts, the type sentence names
/// the position, the type wanted and the type given, and it is
/// underlined at the argument that is wrong rather than at the
/// whole call.  Before this existed each method wrote one sentence
/// for both mistakes — `xs.append("hi")` on a `list[i64]` was told
/// "append takes one element value", which is an answer to a
/// question the reader did not ask, since they passed exactly one.
///
/// A `T?` standing where a `T` belongs collects the same advice it
/// collects anywhere else; that advice is most of what teaches the
/// feature, and dropping it here taught it in one place fewer.
///
/// False after reporting.  `wanted` is positional and its length
/// is the arity.
/// What a method takes, given the receiver it is called on — **the
/// one table**, and null when the receiver has no such method.
///
/// It is consulted twice, which is the whole reason it exists as a
/// function rather than as `&.{...}` in the dispatch below.  Once
/// by `lowerOperandsInto`, *before* an argument is lowered, so a
/// numeric literal lands at the type the receiver names: a number
/// has no type until it meets one (docs/TYPES.md D3), and
/// `xs.append(0.1)` on a `list[f64]` must store binary64's 0.1,
/// not binary32's different nearest value. And once
/// by `methodTakes`, to check what actually arrived.  Two answers
/// from one table cannot disagree; two tables would.
///
/// A **struct** receiver is not answered here: its methods are
/// user declarations, and `landsOn` reads the declaration through
/// `structMethod` so a *named* argument can land at the slot it
/// fills rather than the position it sits at (docs/ARGS.md §4).
/// This table is builtin methods only, and they are positional.
///
/// A string receiver whose name is not a primitive answers null:
/// that call is `strings.name(s, ...)`, a library function with a
/// signature of its own, and the ordinary call path lands its
/// arguments.
pub fn methodParameters(self: *FunctionBuilder, receiver: Type, name: []const u8) Error!?[]const Type {
    if (receiver == .str) {
        for (string_methods) |primitive| {
            if (std.mem.eql(u8, name, primitive.name)) return primitive.takes;
        }
        return null;
    }
    if (receiver == .strukt) {
        if (self.analyzer.interfaceForLayout(receiver.strukt)) |interface_index| {
            for (self.analyzer.interface_decls.items[interface_index].methods) |method| {
                if (std.mem.eql(u8, name, method.declaration.name)) return method.parameter_types;
            }
            return null;
        }
    }
    const descriptor = self.analyzer.heapOf(receiver) orelse return null;
    return switch (descriptor) {
        .class => null,
        .list => |element| sequenceParameters(self, name, element, true),
        .array => |shape| blk: {
            if (std.mem.eql(u8, name, "dim")) break :blk try typeList(self, &.{.i64});
            if (std.mem.eql(u8, name, "fill")) break :blk try typeList(self, &.{shape.element});
            break :blk sequenceParameters(self, name, shape.element, false);
        },
        .map => |pair| blk: {
            if (std.mem.eql(u8, name, "has") or
                std.mem.eql(u8, name, "remove")) break :blk try typeList(self, &.{pair.key});
            if (std.mem.eql(u8, name, "get")) break :blk try typeList(self, &.{pair.key});
            if (std.mem.eql(u8, name, "keys") or
                std.mem.eql(u8, name, "values") or
                std.mem.eql(u8, name, "clear")) break :blk &.{};
            break :blk null;
        },
        .builder => blk: {
            if (std.mem.eql(u8, name, "append")) break :blk try typeList(self, &.{.str});
            if (std.mem.eql(u8, name, "append_ascii")) break :blk try typeList(self, &.{.i64});
            if (std.mem.eql(u8, name, "build") or
                std.mem.eql(u8, name, "clear")) break :blk &.{};
            break :blk null;
        },
        .file => blk: {
            // The buffer is the caller's `array[u8, n]`, and the
            // count a write takes is a `i64`.  Neither landing
            // depends on the receiver, so both are written out.
            if (std.mem.eql(u8, name, "read")) break :blk try typeList(self, &.{
                try resolve.internHeapType(self.analyzer, .{ .array = .{ .element = .u8, .rank = 1 } }),
            });
            if (std.mem.eql(u8, name, "write")) break :blk try typeList(self, &.{
                try resolve.internHeapType(self.analyzer, .{ .array = .{ .element = .u8, .rank = 1 } }),
                .i64,
            });
            if (std.mem.eql(u8, name, "flush")) break :blk &.{};
            break :blk null;
        },
        // `wait` takes nothing: what a worker was given, it was
        // given at the `spawn` (docs/THREADS.md D2).
        .task => if (std.mem.eql(u8, name, "wait")) &.{} else null,
    };
}

/// The list and array half of `methodParameters`.  A `list[T]` and
/// a rank-1 `array[T, _]` answer to the same names; `growable`
/// says which four only a list has.
fn sequenceParameters(
    self: *FunctionBuilder,
    name: []const u8,
    element: Type,
    growable: bool,
) Error!?[]const Type {
    if (growable) {
        if (std.mem.eql(u8, name, "append")) return try typeList(self, &.{element});
        if (std.mem.eql(u8, name, "insert")) return try typeList(self, &.{ .i64, element });
        if (std.mem.eql(u8, name, "remove")) return try typeList(self, &.{.i64});
        if (std.mem.eql(u8, name, "pop")) return &.{};
        if (std.mem.eql(u8, name, "sort_by")) {
            const parameters = try self.arena().alloc(types.Signature.Parameter, 2);
            parameters[0] = .{ .value_type = element };
            parameters[1] = .{ .value_type = element };
            const comparator = try resolve.internSignature(self.analyzer, .{
                .parameters = parameters,
                .result = .boolean,
            });
            return try typeList(self, &.{comparator});
        }
    }
    if (std.mem.eql(u8, name, "sort") or std.mem.eql(u8, name, "reverse")) return &.{};
    if (std.mem.eql(u8, name, "clear") and growable) return &.{};
    if (std.mem.eql(u8, name, "find") or std.mem.eql(u8, name, "contains")) {
        return try typeList(self, &.{element});
    }
    return null;
}

/// A parameter list in arena storage, because the element and key
/// types in one are the receiver's and not compile-time constants.
fn typeList(self: *FunctionBuilder, items: []const Type) Error![]const Type {
    return self.arena().dupe(Type, items);
}

/// Check a method's arguments against the types it takes. Concrete
/// types must match; `fit` only supplies the language's `T` to `T?`
/// injection. The arguments are rewritten in place because these are
/// the registers the caller goes on to pass.
///
/// A literal already landed at this type while it was lowered from
/// this same table (`methodParameters`).
fn methodTakes(
    self: *FunctionBuilder,
    method: ast.Method,
    arguments: []Typed,
    receiver: Type,
) Error!bool {
    // The dispatch below matched this name against the same table,
    // so a null here would mean the two had drifted apart.
    const wanted = (try methodParameters(self, receiver, method.name)).?;
    if (arguments.len != wanted.len) {
        try failMethodArity(self, method, wanted.len);
        return false;
    }
    for (arguments, wanted, 0..) |*argument, want, index| {
        // `fit` rather than a plain comparison because an intrinsic
        // method's parameter can be a `T?`: since D7 a
        // container element may be `(func(...) -> R)?`, so
        // `steps.append(twice)` has to wrap exactly as
        // `var f: (func() -> i64)? = twice` does.
        if (try self.fit(argument.*, want)) |fitted| {
            argument.* = fitted;
            continue;
        }
        try self.fail(
            "luce.sema.type",
            method.arguments[index].span,
            "argument {d} of {s} is {s}, got {s}{s}",
            .{
                index + 1,
                method.name,
                try self.analyzer.typeName(want),
                try self.analyzer.typeName(argument.value_type),
                try refusals.absenceAdvice(self, argument.value_type, method.arguments[index].value),
            },
        );
        return false;
    }
    return true;
}

/// A builtin method handed the wrong number of arguments.
///
/// Said from two places and therefore written in one: the **landing**
/// reaches this conclusion before the extra argument is lowered, so a
/// bare function name written there is never refused for wanting a
/// place the method never had; `methodTakes` reaches it after.  Both
/// count the *written* arguments, which is the one number a reader
/// can see.
pub fn failMethodArity(self: *FunctionBuilder, method: ast.Method, wanted: usize) Error!void {
    try self.fail("luce.sema.method", method.span, "{s} takes {d} argument{s}, got {d}", .{
        method.name,
        wanted,
        helpers.plural(wanted),
        method.arguments.len,
    });
}

/// Route a value method to the std strings module: `s.find(x)` is
/// `strings.find(s, x)`, and `parts.join(sep)` is
/// `strings.join(parts, sep)`.  The language keeps the primitives
/// (literals, +, comparison, slices, len, byte_at); manipulation
/// is library code and needs the import.
fn stringsCall(
    self: *FunctionBuilder,
    method: ast.Method,
    run: OperandRun,
    as_statement: bool,
) Error!?Typed {
    const local_module = std.mem.eql(u8, self.prefix, "strings");
    if (!local_module and !naming.importsModule(self.analyzer, self.module, "strings")) {
        try self.fail(
            "luce.sema.import",
            method.span,
            "str manipulation lives in the standard library: import std.strings to use {s} (docs/STD.md)",
            .{method.name},
        );
        return null;
    }
    // The routed spelling stays positional: the batch landed its
    // arguments from the receiver, not from strings' declaration,
    // so a reordered literal would land at the wrong width.  The
    // static spelling names freely (docs/ARGS.md D10).
    for (method.arguments) |argument| {
        if (argument.name == null) continue;
        try self.fail(
            "luce.sema.method",
            argument.span,
            "{s} routes to std.strings and its arguments are positional here; write strings.{s}(…) to name them",
            .{ method.name, method.name },
        );
        return null;
    }
    const qualified = try std.fmt.allocPrint(self.arena(), "strings.{s}", .{method.name});
    const function_index = self.analyzer.function_names.get(qualified) orelse {
        var suggestion = helpers.Suggestion.init(method.name);
        var entries = self.analyzer.function_names.iterator();
        while (entries.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.key_ptr.*, "strings.")) continue;
            // A withheld helper is not a method anyone is owed
            // (VISIBILITY.md D2).
            const info = self.analyzer.functions.items[entry.value_ptr.*];
            if (info.declaration.visibility == .private and info.module != self.module) continue;
            suggestion.offer(entry.key_ptr.*["strings.".len..]);
        }
        // The reader wrote a method on a string; `strings` is the
        // module it routes to, and answering with the routing
        // target names something they never typed.  Say what they
        // asked about, then where the answer would have lived.
        if (suggestion.best()) |closest| {
            try self.fail("luce.sema.method", method.span, "str has no method {s}; did you mean {s}?", .{ method.name, closest });
        } else {
            try self.fail("luce.sema.method", method.span, "str has no method {s}, and neither has the strings module", .{method.name});
        }
        return null;
    };
    // A `strings` routing is a call like any other, and the
    // module's functions do not fail, so nothing is permitted
    // here: `s.split(",")` can never need a `try`.
    return callUser(self, function_index, qualified, run, method.span, as_statement, false);
}

/// Route `xs.sort_by(before)` to the checked Luce implementation
/// in `std.lists`, specialized at the receiver's element type.
///
/// This is deliberately parallel to `stringsCall`: the import is
/// the feature gate, method arguments stay positional, and the
/// target remains a user function.  The only extra step is closed
/// monomorphization because Luce has monomorphic `list[T]` and no
/// surface generics.  The generated function body is still the
/// std source, so neither MIR nor libluce_rt learns a sort callback.
fn listsCall(
    self: *FunctionBuilder,
    method: ast.Method,
    run: OperandRun,
    element: Type,
    as_statement: bool,
) Error!?Typed {
    const local_module = naming.isStandardModule(self.analyzer, self.module, "lists");
    if (!local_module and !naming.importsStandardModule(self.analyzer, self.module, "lists")) {
        try self.fail(
            "luce.sema.import",
            method.span,
            "comparator sorting lives in the standard library: import std.lists to use sort_by (docs/STD.md)",
            .{},
        );
        return null;
    }
    for (method.arguments) |argument| {
        if (argument.name == null) continue;
        try self.fail(
            "luce.sema.method",
            argument.span,
            "sort_by routes to std.lists and its comparator is positional here; write sort_by(before)",
            .{},
        );
        return null;
    }
    const comparator = (try sequenceParameters(self, "sort_by", element, true)).?[0];
    const receiver_type = run.values[0].value_type;
    const element_name = try self.analyzer.typeName(element);
    const specialized_name = try std.fmt.allocPrint(
        self.arena(),
        "lists.sort_by({s})",
        .{element_name},
    );
    const function_index = (try signatures.registerStandardSpecialization(
        self.analyzer,
        "lists.sort_by_template",
        specialized_name,
        &.{ receiver_type, comparator },
    )) orelse {
        try self.fail(
            "luce.sema.import",
            method.span,
            "std.lists is missing its sort_by implementation",
            .{},
        );
        return null;
    };
    return callUser(self, function_index, "lists.sort_by", run, method.span, as_statement, false);
}

/// The emitting half of a user call, for callers that already
/// lowered their operands (method routing): arity and type checks
/// against the signature, then the call instruction.
fn callUser(
    self: *FunctionBuilder,
    function_index: u32,
    name: []const u8,
    run: OperandRun,
    span: Span,
    as_statement: bool,
    fallible_allowed: bool,
) Error!?Typed {
    const values = run.values;
    // The method sugar routes to the same declaration and the same
    // refusal, so the leak has no second door (VISIBILITY.md §1):
    // `s.fold_case(…)` arrives here as `strings.fold_case`.
    if (!try refusals.functionReachable(self, function_index, span)) return null;
    const info = self.analyzer.functions.items[function_index];
    // **The whole of why a swallowed failure is unwritable.**  A
    // function that says it can fail cannot be called as if it
    // could not, so `if files.write_lines(...)` with no else is a
    // shape the grammar no longer has (docs/FAILURE.md).
    if (info.fallible and !fallible_allowed) {
        try self.fail(
            "luce.sema.fallible",
            span,
            "{s} can fail: write 'try {s}(…)' to pass the error on, or '{s}(…) catch …' to handle it",
            .{ name, name, name },
        );
        return null;
    }
    const total = info.parameter_types.len;
    if (info.parameter_defaults.len != total) return null; // the declaration already carries a diagnostic
    const covered = values.len <= total and covered: {
        for (info.parameter_defaults[values.len..]) |default| {
            if (default == null) break :covered false;
        }
        break :covered true;
    };
    if (!covered) {
        var defaulted: usize = 0;
        for (info.parameter_defaults) |default| {
            if (default != null) defaulted += 1;
        }
        if (defaulted != 0) {
            const required = total - defaulted;
            try self.fail("luce.sema.call", span, "{s} takes {d} argument{s} and {d} with a default, got {d}", .{
                name,
                required,
                helpers.plural(required),
                defaulted,
                values.len,
            });
        } else {
            try self.fail("luce.sema.call", span, "{s} takes {d} argument{s}, got {d}", .{
                name,
                total,
                helpers.plural(total),
                values.len,
            });
        }
        return null;
    }
    const entries = try self.arena().alloc(RecordedOperand, total);
    for (values, 0..) |value, index| {
        const fitted = (try self.fit(value, info.parameter_types[index])) orelse {
            try self.fail("luce.sema.type", span, "argument {d} of {s} is {s}, got {s}{s}", .{
                index + 1,
                name,
                try self.analyzer.typeName(info.parameter_types[index]),
                try self.analyzer.typeName(value.value_type),
                try refusals.absenceAdvice(self, value.value_type, null),
            });
            return null;
        };
        // The routed spelling is positional whole: slot i is
        // operand i, the receiver first.
        entries[index] = .{
            .node = fitted.node,
            .slot = @intCast(index),
            .copied = run.copied[index],
        };
    }
    // The suffix the call omitted takes its defaults — how the
    // routed spelling `s.find(x)` reaches a `find` with a
    // defaulted `start` (docs/ARGS.md D2, D3).
    for (info.parameter_defaults[values.len..], values.len..) |maybe_default, slot| {
        const filled = maybe_default.?;
        const made = try expressions.emitConstantValue(self, filled.value, filled.value_type, span);
        try ledger.parkFreshStorage(self, made, span);
        entries[slot] = .{
            .node = made.node,
            .slot = @intCast(slot),
        };
    }
    if (info.return_type == .none and !as_statement) {
        try self.fail("luce.sema.call", span, "{s} returns nothing", .{name});
        return null;
    }
    const node = try recorder.recordCallNode(
        self,
        .{ .function = function_index },
        entries,
        values.len,
        info.fallible,
        info.return_type,
        span,
    );
    if (info.fallible) return try self.openFallible(info.return_type, node, span);
    // A function's result is the caller's (S16): fresh storage.
    return .{ .node = node, .value_type = info.return_type };
}

// Method tables, by receiver shape ----------------------------------------

/// The one sentence for a builtin method name a receiver shape does
/// not answer to.
///
/// Said from two places and therefore written in one: the **landing**
/// reaches this conclusion with the receiver lowered and nothing else
/// — which is what keeps `m.put(k, f)` answering *"map has no method
/// put"* instead of refusing `f` for wanting a place that will never
/// exist — and the **dispatch** below reaches it after the arguments
/// are in hand.  Two copies would be two sentences for one fact, and
/// the one a reader met less often would go stale.
fn failNoObjectMethod(self: *FunctionBuilder, method: ast.Method, descriptor: types.HeapType) Error!void {
    const name = method.name;
    var suggestion = helpers.Suggestion.init(name);
    switch (descriptor) {
        .class => unreachable, // nominal methods are resolved before builtin dispatch
        .list => {
            suggestion.offerAll(&list_methods);
            if (suggestion.best()) |closest| {
                try self.fail("luce.sema.method", method.span, "list has no method {s}; did you mean {s}?", .{ name, closest });
                return;
            }
            try self.fail("luce.sema.method", method.span, "list has no method {s} (has append insert remove pop sort reverse find contains clear; sort_by lives in lists; join lives in strings)", .{name});
        },
        .array => |shape| {
            // Only a rank-1 array answers to the sequence methods:
            // a higher rank is indexed down to one first, and that
            // is the sentence a reader who wrote `grid.sort()`
            // needs rather than a did-you-mean.
            if (shape.rank != 1) {
                try self.fail("luce.sema.method", method.span, "only rank-1 arrays have {s}; index higher ranks", .{name});
                return;
            }
            suggestion.offerAll(&array_methods);
            if (suggestion.best()) |closest| {
                try self.fail("luce.sema.method", method.span, "array has no method {s}; did you mean {s}?", .{ name, closest });
                return;
            }
            try self.fail("luce.sema.method", method.span, "array has no method {s} (has dim fill sort reverse find contains)", .{name});
        },
        .map => {
            suggestion.offerAll(&map_methods);
            if (suggestion.best()) |closest| {
                try self.fail("luce.sema.method", method.span, "map has no method {s}; did you mean {s}?", .{ name, closest });
                return;
            }
            try self.fail("luce.sema.method", method.span, "map has no method {s} (has get remove keys values clear)", .{name});
        },
        .builder => {
            suggestion.offerAll(&builder_methods);
            if (suggestion.best()) |closest| {
                try self.fail("luce.sema.method", method.span, "builder has no method {s}; did you mean {s}?", .{ name, closest });
                return;
            }
            try self.fail("luce.sema.method", method.span, "builder has no method {s} (append append_ascii build clear)", .{name});
        },
        .file => {
            // The one name a Python programmer will certainly type,
            // answered in full rather than left to a did-you-mean
            // (docs/FILESYSTEM.md D9).  It is **refused** and not
            // merely absent: `free f` already closes it and so does
            // the end of the owning scope, so a working `close` would
            // be a second name for one concept.  Both halves of the
            // answer are here, because a reader who wanted `close`
            // also wanted `with`.
            if (std.mem.eql(u8, name, "close")) {
                try self.fail(
                    "luce.sema.method",
                    method.span,
                    "file has no method close: free f closes it, and the end of the owning scope closes it anyway — which is why there is no 'with' either (docs/FILESYSTEM.md)",
                    .{},
                );
                return;
            }
            suggestion.offerAll(&file_methods);
            if (suggestion.best()) |closest| {
                try self.fail("luce.sema.method", method.span, "file has no method {s}; did you mean {s}?", .{ name, closest });
                return;
            }
            try self.fail(
                "luce.sema.method",
                method.span,
                "file has no method {s} (read write flush; free f closes it, and so does the end of the owning scope)",
                .{name},
            );
        },
        .task => {
            suggestion.offerAll(&task_methods);
            if (suggestion.best()) |closest| {
                try self.fail("luce.sema.method", method.span, "task has no method {s}; did you mean {s}?", .{ name, closest });
                return;
            }
            try self.fail("luce.sema.method", method.span, "task has no method {s} (wait; free t joins it)", .{name});
        },
    }
}

/// Whether this receiver answers to no method by this name at all —
/// true when the refusal above has been said.
///
/// Asked by the landing, with operand zero lowered and nothing else,
/// so that a receiver's own answer comes before any sentence about an
/// argument.  It is deliberately conservative: **routing is not
/// absence.**  A string's non-primitive methods are `strings`
/// functions and `parts.join(sep)` is one too, so whether those names
/// exist is `stringsCall`'s answer, not this one; a `list`'s
/// `sort_by` is a `lists` function, and it is in `methodParameters`,
/// so this is never asked about it.
pub fn failAbsentMethod(self: *FunctionBuilder, receiver: Type, method: ast.Method) Error!bool {
    if (receiver == .str) return false;
    const descriptor = self.analyzer.heapOf(receiver) orelse return false;
    if (descriptor == .list and descriptor.list == .str and
        std.mem.eql(u8, method.name, "join")) return false;
    try failNoObjectMethod(self, method, descriptor);
    return true;
}

/// The declared receiver's half of the question above: `p.foo(f)`
/// where `Point` declares no `foo` at all.  True when it reported.
///
/// A name that *is* declared and is not a method — a `static func`,
/// or one this module may not see — is the dispatch's sentence, one
/// step further on: this one is only about the name being there.
pub fn failAbsentReceiverMethod(self: *FunctionBuilder, receiver: Type, method: ast.Method) Error!bool {
    const declared = declaredName(self, receiver) orelse return false;
    const qualified = try std.fmt.allocPrint(self.temporary(), "{s}.{s}", .{ declared, method.name });
    defer self.temporary().free(qualified);
    if (self.analyzer.function_names.contains(qualified)) return false;
    try failUnknownMethod(self, receiver, declared, method);
    return true;
}

/// Whether any argument of a call was written with a name in front
/// of it (`xs.append(value = 1)`).
pub fn namesAnyArgument(arguments: []const ast.Argument) bool {
    for (arguments) |argument| {
        if (argument.name != null) return true;
    }
    return false;
}

/// `descriptor` is the receiver's *shape*, which is everything the
/// dispatch below turns on: a `list[i64]` and a `list[str]`
/// answer to the same method names and differ only in what the
/// element type makes of the arguments, and the descriptor carries
/// that.  The receiver's `Type` adds nothing on top of it.
fn objectMethod(
    self: *FunctionBuilder,
    method: ast.Method,
    receiver: Type,
    descriptor: types.HeapType,
    arguments: []Typed,
) Error!?MethodFound {
    const name = method.name;
    switch (descriptor) {
        .class => unreachable, // nominal methods are resolved before builtin dispatch
        .list => |element| return sequenceMethod(self, method, receiver, element, true, arguments),
        .array => |shape| {
            if (std.mem.eql(u8, name, "dim")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .dim_size, .result = .i64 };
            }
            if (std.mem.eql(u8, name, "fill")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .array_fill, .result = .none };
            }
            if (shape.rank != 1) {
                try failNoObjectMethod(self, method, descriptor);
                return null;
            }
            return sequenceMethod(self, method, receiver, shape.element, false, arguments);
        },
        .map => |pair| {
            if (std.mem.eql(u8, name, "has")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .has_key, .result = .boolean };
            }
            if (std.mem.eql(u8, name, "remove")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .remove_entry, .result = .none };
            }
            if (std.mem.eql(u8, name, "keys")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .map_keys, .result = try resolve.internHeapType(self.analyzer, .{ .list = pair.key }) };
            }
            if (std.mem.eql(u8, name, "values")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                // **`values()` manufactures a list type, and a bare
                // function type is not a list element** (docs/BINDING.md
                // D7).  A map value is the one slot written bare, because
                // `get` already answers `V?` — so
                // `map[str, func(i64) -> i64]` is legal while a list of bare
                // function values is a
                // type no program can write.  Manufacturing one anyway
                // produced a program `luce check` accepted and the
                // backend could not lower: a list cell has no shape for a
                // bare function, and `cellType` said so with an
                // `unreachable`.  Refused where the list would be made,
                // naming the loop that does work.
                if (pair.value == .function) {
                    try self.fail(
                        "luce.sema.type",
                        method.span,
                        "map.values() would answer list[{s}], and a bare function type is not a list element — the storable " ++
                            "form is ({s})?, which a map value is deliberately not written as; walk m.keys() and read m.get(k) " ++
                            "instead",
                        .{ try self.analyzer.typeName(pair.value), try self.analyzer.typeName(pair.value) },
                    );
                    return null;
                }
                return .{ .kind = .map_values, .result = try resolve.internHeapType(self.analyzer, .{ .list = pair.value }) };
            }
            if (std.mem.eql(u8, name, "get")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                // `m.get(k)` answers `V?`: absence is the honest
                // shape for "not there", and `m.get(k) else d` is
                // the old fallback form spelled with the
                // language's own absence machinery.  A map value
                // cannot itself be optional, so the wrap always
                // exists.
                return .{ .kind = .map_get, .result = Type.optionalOf(pair.value).? };
            }
            if (std.mem.eql(u8, name, "clear")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .clear_object, .result = .none };
            }
            try failNoObjectMethod(self, method, descriptor);
            return null;
        },
        .builder => {
            // The method a builder should always have had.  Its
            // text used to come out through `b.build()`, which made
            // the one free builtin that took a heap object — and
            // is why `str` could not simply be renamed
            // `str` (docs/NUMERICS.md §7).
            if (std.mem.eql(u8, name, "build")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .str_value, .result = .str };
            }
            if (std.mem.eql(u8, name, "append")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .append_value, .result = .none };
            }
            if (std.mem.eql(u8, name, "append_ascii")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .append_ascii, .result = .none };
            }
            if (std.mem.eql(u8, name, "clear")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .clear_object, .result = .none };
            }
            try failNoObjectMethod(self, method, descriptor);
            return null;
        },
        // The byte channel (docs/BYTES.md R4).  A read fills the
        // caller's buffer and answers how many bytes landed — zero
        // is the end of the file — and a write takes a buffer and
        // a count and answers how many landed.  All three are
        // fallible: the world decides.  There is no `close`,
        // because `free f` is one and the end of the owning scope
        // is the other (MEMORY.md, unchanged).
        .file => {
            if (std.mem.eql(u8, name, "read")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .handle_read, .result = .i64 };
            }
            if (std.mem.eql(u8, name, "write")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .handle_write, .result = .i64 };
            }
            if (std.mem.eql(u8, name, "flush")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .handle_flush, .result = .none };
            }
            try failNoObjectMethod(self, method, descriptor);
            return null;
        },
        // A task's one method (docs/THREADS.md D4).  It consumes
        // the task, which `lowerReceiverCall` poisons the receiver
        // for, and it answers what the worker answered — including
        // the worker's error, when the task carries a fallible
        // call.
        .task => |work| {
            if (std.mem.eql(u8, name, "wait")) {
                if (!try methodTakes(self, method, arguments, receiver)) return null;
                return .{ .kind = .task_wait, .result = work.result };
            }
            try failNoObjectMethod(self, method, descriptor);
            return null;
        },
    }
}

/// The task shape a type holds, or null when it holds anything
/// else (docs/THREADS.md D3).
fn taskShape(
    self: *const FunctionBuilder,
    of: Type,
) ?@FieldType(types.HeapType, "task") {
    if (of != .heap) return null;
    const shape = self.analyzer.heap_types.items[of.heap];
    return if (shape == .task) shape.task else null;
}

/// Methods shared by list and rank-1 array; growth operations are
/// list-only.
fn sequenceMethod(
    self: *FunctionBuilder,
    method: ast.Method,
    receiver: Type,
    element: Type,
    growable: bool,
    arguments: []Typed,
) Error!?MethodFound {
    const name = method.name;
    if (growable) {
        if (std.mem.eql(u8, name, "append")) {
            if (!try methodTakes(self, method, arguments, receiver)) return null;
            return .{ .kind = .append_value, .result = .none };
        }
        if (std.mem.eql(u8, name, "insert")) {
            if (!try methodTakes(self, method, arguments, receiver)) return null;
            return .{ .kind = .insert_value, .result = .none };
        }
        if (std.mem.eql(u8, name, "remove")) {
            if (!try methodTakes(self, method, arguments, receiver)) return null;
            return .{ .kind = .remove_entry, .result = .none };
        }
        if (std.mem.eql(u8, name, "pop")) {
            if (!try methodTakes(self, method, arguments, receiver)) return null;
            return .{ .kind = .pop_value, .result = element };
        }
        if (std.mem.eql(u8, name, "clear")) {
            if (!try methodTakes(self, method, arguments, receiver)) return null;
            return .{ .kind = .clear_object, .result = .none };
        }
    }
    if (std.mem.eql(u8, name, "sort")) {
        if (!try methodTakes(self, method, arguments, receiver)) return null;
        const ordered = element.isNumeric() or element == .char or element == .str or element == .bytes;
        if (!ordered) return methodFail(self, method, "sort orders numbers, char, str, or bytes elements");
        return .{ .kind = .list_sort, .result = .none };
    }
    if (std.mem.eql(u8, name, "reverse")) {
        if (!try methodTakes(self, method, arguments, receiver)) return null;
        return .{ .kind = .list_reverse, .result = .none };
    }
    if (std.mem.eql(u8, name, "find") or std.mem.eql(u8, name, "contains")) {
        // **Both look with `==`, so both refuse exactly what `==`
        // refuses** — and the question is about the whole element, not
        // about its outermost tag.  A function value has no equality
        // (docs/BINDING.md D6) and `match` is the only door into a
        // union (docs/UNION.md D16); a `list[Button]` whose `Button`
        // holds either reaches the runtime's comparator, which has no
        // sentence to say and reaches its `unreachable` instead.  One
        // walk answers here and at `==`, which is what keeps the two
        // spellings of one refusal from drifting apart again.
        if (try shapes.incomparablePart(self.analyzer, element)) |found| {
            try refusals.failUnsearchable(self, found, element, name, method.span);
            return null;
        }
    }
    if (std.mem.eql(u8, name, "find")) {
        if (!try methodTakes(self, method, arguments, receiver)) return null;
        // `xs.find(v)` answers `i64?`, not a -1 sentinel: the
        // same absence rule `m.get` and `strings.find` follow, so
        // a package corpus never bakes the sentinel in.
        return .{ .kind = .list_find, .result = .{ .optional = .i64 } };
    }
    if (std.mem.eql(u8, name, "contains")) {
        if (!try methodTakes(self, method, arguments, receiver)) return null;
        return .{ .kind = .list_contains, .result = .boolean };
    }
    // Which shape the reader wrote on is the whole of what is left
    // to say: map and builder both name themselves, and a reader who
    // mistook a list for a map needs exactly that.  The sentence is
    // `failNoObjectMethod`'s, so the landing says the same one.
    try failNoObjectMethod(self, method, self.analyzer.heapOf(receiver).?);
    return null;
}
