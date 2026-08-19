//! A written type name to a `Type`.
//!
//! One question with one answer.  `resolveType` takes what stage 3
//! wrote down — a name, its type arguments, its shape wildcards, its
//! trailing `?` — and answers the type it names, or reports why it
//! names nothing.  Everything else here serves that one call: the
//! builtin table's arms and their arity sentences, the written
//! function type, the two "not yet" walls a container part meets, the
//! did-you-mean a misremembered spelling gets, and the interning that
//! keeps one index per distinct heap shape and signature.
//!
//! **The interning is here because resolution is what mints a row.**
//! A `list[i64]` a program wrote and a `list[i64]` a checked
//! `xs[a:b]` needs are the same row, and keeping the mint beside the
//! only spelling that reaches it from source is what makes two rows
//! for one shape hard to write.  What the tables mean once they are
//! filled — what a type carries, how wide it is — is `shapes.zig`.
//!
//! Free functions over `declarations.zig`'s `*Analyzer`; `pub` means
//! visible to stage 4's own files, nothing wider.

const std = @import("std");
const ast = @import("../parse.zig").ast;
const types = @import("../support/types.zig");
const helpers = @import("helpers.zig");
const source_mod = @import("../source.zig");

const naming = @import("naming.zig");

const context = @import("context.zig");
const Error = context.Error;
const Span = source_mod.Span;
const Type = types.Type;
const Analyzer = @import("declarations.zig").Analyzer;

/// Resolve a written type, including a trailing `?`.
///
/// `T?` is a type; `T??` has no representation to resolve into and
/// stage 3 refuses it before this ever sees it.
pub fn resolveType(self: *Analyzer, module: usize, written: ast.TypeName) Error!?Type {
    const base = (try resolveBase(self, module, written)) orelse return null;
    if (!written.optional) return base;
    return Type.optionalOf(base) orelse {
        try self.fail(
            "luce.sema.type",
            written.span,
            "{s}? is not a type: {s} is already optional",
            .{ written.name, try self.typeName(base) },
        );
        return null;
    };
}

/// Resolve one alias row, guarding recursion and applying visibility at the
/// written use.  The cached answer is the underlying `Type`: there is no alias
/// tag for later stages to accidentally give distinct behavior.
pub fn resolveAlias(
    self: *Analyzer,
    from_module: usize,
    alias_index: u32,
    use_span: Span,
) Error!?Type {
    const initial = self.alias_decls.items[alias_index];
    if (!naming.reachable(initial.module, initial.declaration.visibility, from_module)) {
        try self.fail("luce.sema.private", use_span, "{s} is private to {s}", .{
            initial.declaration.name,
            naming.moduleName(self, initial.module),
        });
        return null;
    }
    switch (initial.state) {
        .ready => return initial.resolved,
        .failed => return null,
        .resolving => {
            var path: std.ArrayList(u8) = .empty;
            defer path.deinit(self.temporary);
            var start: usize = 0;
            while (start < self.alias_stack.items.len and self.alias_stack.items[start] != alias_index) : (start += 1) {}
            for (self.alias_stack.items[start..]) |index| {
                if (path.items.len != 0) try path.appendSlice(self.temporary, " -> ");
                try path.appendSlice(self.temporary, self.alias_decls.items[index].declaration.name);
            }
            if (path.items.len != 0) try path.appendSlice(self.temporary, " -> ");
            try path.appendSlice(self.temporary, initial.declaration.name);
            try self.fail(
                "luce.sema.alias",
                use_span,
                "type alias cycle: {s}; an alias must end at a concrete type",
                .{path.items},
            );
            self.alias_decls.items[alias_index].state = .failed;
            return null;
        },
        .pending => {},
    }

    self.alias_decls.items[alias_index].state = .resolving;
    try self.alias_stack.append(self.temporary, alias_index);
    defer _ = self.alias_stack.pop();
    const declaration = self.alias_decls.items[alias_index].declaration;
    const owner = self.alias_decls.items[alias_index].module;
    const target = (try resolveType(self, owner, declaration.target)) orelse {
        self.alias_decls.items[alias_index].state = .failed;
        return null;
    };
    self.alias_decls.items[alias_index].resolved = target;
    self.alias_decls.items[alias_index].state = .ready;
    return target;
}

/// The declaration namespace carried by a resolved nominal type.  Aliases do
/// not create a second namespace; expression sites rewrite through this name
/// before looking up constructors, enum/union members, or static functions.
/// Scalars and anonymous compound types have no declaration namespace.
pub fn namespaceName(self: *Analyzer, target: Type) ?[]const u8 {
    return switch (target) {
        .strukt => |index| self.structs.items[index].name,
        .heap => |index| switch (self.heap_types.items[index]) {
            .class => |layout| self.structs.items[layout].name,
            else => null,
        },
        .enumeration => |reference| self.enums.items[reference.index].name,
        .variant => |index| self.variants.items[index].name,
        else => null,
    };
}

/// The `?` that a container element may not carry.  Refused in v1
/// (docs/FAILURE.md): `[1, none, none, 2]` would need a
/// representation for an absent element that the containers do not
/// have, and PEP 505's objection to that gap is the one that
/// transfers.
///
/// **A function payload is the one exception, and it is not one**:
/// `(func() -> i64)?` is the *only* form a function value takes in a
/// slot (docs/BINDING.md D7), because a function value has no zero and
/// a slot exists before anything fills it.  So the absence is not a
/// second way to spell an element type here; it is the element type,
/// and the objection above — that an absent element has no
/// representation — is answered by the absence `T?` already is.
pub fn refuseOptionalPart(
    self: *Analyzer,
    part: Type,
    written: ast.TypeName,
    role: []const u8,
) Error!bool {
    if (part != .optional) return false;
    if (part.optional == .function) return false;
    try self.fail("luce.sema.type", written.span, "a {s} cannot be optional: write {s} and keep the absence in a name of its own", .{
        role,
        try self.typeName(part.held().?),
    });
    return true;
}

fn resolveBase(self: *Analyzer, module: usize, written: ast.TypeName) Error!?Type {
    // `func(T, ...) -> R`.  Not in the builtin table because it is
    // not a name a program could have written for something else:
    // `func` is a keyword, so this shape reaches here from the
    // parser and from nowhere a reader could collide with.
    if (written.result != null or std.mem.eql(u8, written.name, "func")) {
        return resolveSignature(self, module, written);
    }
    // A standard-only spelling (`handle`) is the language's inside
    // embedded standard source and an ordinary name everywhere else —
    // the type-name half of the `Builtin.NAME` gate.  Falling through
    // here, rather than failing, is what lets a program own the word.
    if (naming.visibleBuiltin(self, module, written.name)) |builtin| switch (builtin) {
        .boolean, .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f16, .f32, .f64, .char, .str, .bytes => {
            if (written.arguments.len != 0 or written.wildcards != 0) {
                try self.fail("luce.sema.type", written.span, "{s} takes no type arguments", .{written.name});
                return null;
            }
            return switch (builtin) {
                .boolean => .boolean,
                .u8 => .u8,
                .u16 => .u16,
                .u32 => .u32,
                .u64 => .u64,
                .i8 => .i8,
                .i16 => .i16,
                .i32 => .i32,
                .i64 => .i64,
                .f16 => .f16,
                .f32 => .f32,
                .f64 => .f64,
                .char => .char,
                .str => .str,
                .bytes => .bytes,
                .list, .map, .array, .builder, .handle, .task, .channel => unreachable, // answered by the outer switch
            };
        },
        .list => {
            if (written.arguments.len != 1 or written.wildcards != 0) {
                try self.fail("luce.sema.container.type", written.span, "list takes one element type: list[i64]", .{});
                return null;
            }
            const element = (try resolveType(self, module, written.arguments[0])) orelse return null;
            if (try refuseOptionalPart(self, element, written.arguments[0], "list element")) return null;
            if (try refuseFunctionPart(self, element, written.arguments[0].span, "list element")) return null;
            return try internHeapType(self, .{ .list = element });
        },
        .channel => {
            if (written.arguments.len != 1 or written.wildcards != 0) {
                try self.fail("luce.sema.container.type", written.span, "channel takes one element type: channel[i64]", .{});
                return null;
            }
            const element = (try resolveType(self, module, written.arguments[0])) orelse return null;
            if (try refuseOptionalPart(self, element, written.arguments[0], "channel element")) return null;
            if (try refuseFunctionPart(self, element, written.arguments[0].span, "channel element")) return null;
            // The element must be sendable *by type*: a channel exists
            // to cross workers, and a value that cannot cross must be
            // refused where the channel is written, not where a send
            // finally trips (docs/THREADS.md).
            if (try refuseUnsendablePart(self, element, written.arguments[0].span)) return null;
            return try internHeapType(self, .{ .channel = element });
        },
        .map => {
            if (written.arguments.len != 2 or written.wildcards != 0) {
                try self.fail("luce.sema.container.type", written.span, "map takes key and value types: map[str, i64]", .{});
                return null;
            }
            const key = (try resolveType(self, module, written.arguments[0])) orelse return null;
            // **A key is an integer, a `str`, or an enum.**
            // (docs/ENUMS.md, As built 2026-08-12).  An enum is an
            // integer at a chosen width whose entire comparison surface
            // is equality, which is exactly and only what a key needs;
            // It reaches the runtime at its explicit backing width.
            if (!key.isInteger() and key != .str and key != .enumeration) {
                // A union has no number and no key form at all
                // (docs/UNION.md D15): the sentence offers the one
                // move that exists — keep it in the value.
                if (key == .variant) {
                    try self.fail(
                        "luce.sema.type",
                        written.arguments[0].span,
                        "map keys are an integer, str or an enum; a union has no key form — keep {s} in the value and key by what identifies it",
                        .{try self.typeName(key)},
                    );
                    return null;
                }
                try self.fail(
                    "luce.sema.type",
                    written.arguments[0].span,
                    "map keys are an integer, str or an enum, got {s}",
                    .{try self.typeName(key)},
                );
                return null;
            }
            const value = (try resolveType(self, module, written.arguments[1])) orelse return null;
            // **A map value is the one slot no container ever creates.**
            // A list cell, an array cell and a struct field all exist,
            // zeroed, before anything fills them, which is why a
            // function value takes its optional form in those
            // (docs/BINDING.md D7).  A map value exists because `put`
            // created it, and `get` already answers `V?` — so the
            // absence D7 asks for is the missing key, the type is
            // written bare, and there is no `refuseFunctionPart` here.
            // Writing the `?` as well would make `get` answer a `V??`,
            // which has no representation to answer with.
            if (value == .optional and value.optional == .function) {
                try self.fail(
                    "luce.sema.type",
                    written.arguments[1].span,
                    "a map value is written bare: get already answers {s}, and a second '?' would be a V??",
                    .{try self.typeName(value)},
                );
                return null;
            }
            if (try refuseOptionalPart(self, value, written.arguments[1], "map value")) return null;
            return try internHeapType(self, .{ .map = .{ .key = key, .value = value } });
        },
        .array => {
            if (written.arguments.len != 1 or written.wildcards == 0 or written.wildcards > 4) {
                try self.fail(
                    "luce.sema.type",
                    written.span,
                    "array spells element and rank: array[i64, _] up to array[i64, _, _, _, _]",
                    .{},
                );
                return null;
            }
            const element = (try resolveType(self, module, written.arguments[0])) orelse return null;
            if (try refuseOptionalPart(self, element, written.arguments[0], "array element")) return null;
            if (try refuseFunctionPart(self, element, written.arguments[0].span, "array element")) return null;
            return try internHeapType(self, .{ .array = .{ .element = element, .rank = written.wildcards } });
        },
        .builder => {
            if (written.arguments.len != 0 or written.wildcards != 0) {
                try self.fail("luce.sema.type", written.span, "builder takes no type arguments", .{});
                return null;
            }
            return try internHeapType(self, .builder);
        },
        .handle => {
            if (written.arguments.len != 0 or written.wildcards != 0) {
                try self.fail("luce.sema.type", written.span, "handle takes no type arguments", .{});
                return null;
            }
            return try internHeapType(self, .handle);
        },
        // `task[...]` holds one **return shape**, written as
        // `task[f64]`, `task[f64!]`, `task[!]`, or bare `task` for a worker that answers
        // nothing and cannot fail (docs/THREADS.md D3).  The `!` is
        // the spawned function's own attribute travelling with the
        // call the task carries — `types.Type` is untouched by it,
        // exactly as `Function.fallible` leaves it untouched.
        .task => {
            if (written.wildcards != 0 or written.arguments.len > 1) {
                try self.fail("luce.sema.container.type", written.span, "task holds one answer: task[T], task[T!], task[!], or task", .{});
                return null;
            }
            var answered: Type = .none;
            if (written.arguments.len == 1) {
                answered = (try resolveType(self, module, written.arguments[0])) orelse return null;
            }
            return try internHeapType(self, .{
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
        if (self.variant_names.get(try naming.qualify(self, self.modules[module].prefix, head))) |index| {
            try self.fail(
                "luce.sema.union",
                written.span,
                "a member is not a type: every member of {s} is a {s}, so write {s}",
                .{ self.variant_decls.items[index].declaration.name, self.variant_decls.items[index].declaration.name, head },
            );
            return null;
        }
        if (!naming.importsModule(self, module, head)) {
            try self.fail("luce.sema.import", written.span, "unknown module {s}; import {s} to use its types", .{ head, try naming.importSpelling(self, head) });
            return null;
        }
        const key = try naming.importedName(self, module, written.name);
        if (self.alias_names.get(key)) |index| return resolveAlias(self, module, index, written.span);
        if (self.interface_names.get(key)) |interface_index| {
            const info = self.interface_decls.items[interface_index];
            if (!naming.reachable(info.module, info.declaration.visibility, module)) {
                try self.fail("luce.sema.private", written.span, "{s} is private to {s}", .{
                    info.declaration.name,
                    naming.moduleName(self, info.module),
                });
                return null;
            }
            return .{ .strukt = info.layout };
        }
        if (self.struct_names.get(key)) |index| {
            // Private is not unknown (VISIBILITY.md D2): the name
            // exists and is withheld, and the sentence says which.
            const info = self.struct_decls.items[index];
            if (!naming.reachable(info.module, info.declaration.visibility, module)) {
                try self.fail(
                    "luce.sema.private",
                    written.span,
                    "{s} is private to {s}",
                    .{ info.declaration.name, naming.moduleName(self, info.module) },
                );
                return null;
            }
            return try nominalType(self, index);
        }
        if (self.enum_names.get(key)) |index| {
            const info = self.enum_decls.items[index];
            if (!naming.reachable(info.module, info.declaration.visibility, module)) {
                try self.fail(
                    "luce.sema.private",
                    written.span,
                    "{s} is private to {s}",
                    .{ info.declaration.name, naming.moduleName(self, info.module) },
                );
                return null;
            }
            return self.enumType(index);
        }
        if (self.variant_names.get(key)) |index| {
            const info = self.variant_decls.items[index];
            if (!naming.reachable(info.module, info.declaration.visibility, module)) {
                try self.fail(
                    "luce.sema.private",
                    written.span,
                    "{s} is private to {s}",
                    .{ info.declaration.name, naming.moduleName(self, info.module) },
                );
                return null;
            }
            return .{ .variant = index };
        }
        try failUnknownType(self, module, written);
        return null;
    }
    const local = try naming.qualify(self, self.modules[module].prefix, written.name);
    if (self.alias_names.get(local)) |index| return resolveAlias(self, module, index, written.span);
    if (self.interface_names.get(local)) |interface_index| return .{ .strukt = self.interface_decls.items[interface_index].layout };
    if (self.struct_names.get(local)) |index| return try nominalType(self, index);
    if (self.enum_names.get(local)) |index| return self.enumType(index);
    if (self.variant_names.get(local)) |index| return .{ .variant = index };
    // A member import binds the bare name: after `from geo import
    // Point`, this is the qualified lookup with the member's own key.
    // Reachability was settled where the import was written, so no
    // per-use privacy check repeats here.
    if (try naming.memberKey(self, module, written.name)) |key| {
        if (self.alias_names.get(key)) |index| return resolveAlias(self, module, index, written.span);
        if (self.interface_names.get(key)) |interface_index| return .{ .strukt = self.interface_decls.items[interface_index].layout };
        if (self.struct_names.get(key)) |index| return try nominalType(self, index);
        if (self.enum_names.get(key)) |index| return self.enumType(index);
        if (self.variant_names.get(key)) |index| return .{ .variant = index };
    }
    try failUnknownType(self, module, written);
    return null;
}

/// `func(T, ...) -> R` — the written function type, interned
/// (docs/FUNCTIONS.md S2).
///
/// **A bare function type stands where a value is always present**: a
/// parameter, a `let`, a return, a map value installed with its key, or a
/// custom-initialized class field. Where a zero-created slot exists before
/// anything fills it — a memberwise aggregate field or container element —
/// the type is written `(func(...) -> R)?` (docs/BINDING.md D7).
fn resolveSignature(self: *Analyzer, module: usize, written: ast.TypeName) Error!?Type {
    const parameters = try self.arena.alloc(types.Signature.Parameter, written.arguments.len);
    for (written.arguments, parameters) |part, *parameter| {
        const resolved = (try resolveType(self, module, part)) orelse return null;
        parameter.* = .{ .value_type = resolved };
    }
    var result: Type = .none;
    if (written.result) |answered| {
        result = (try resolveType(self, module, answered.*)) orelse return null;
    }
    return try internSignature(self, .{ .parameters = parameters, .result = result });
}

/// The `?` a function type is told to wear where it stands in a slot.
///
/// A memberwise aggregate field and a container element exist before anything
/// fills them, and a function value has no zero: every value of the type names
/// a function, and an empty slot names none. So those positions use
/// `(func(...) -> R)?`, whose zero is absence (docs/BINDING.md D7). A
/// custom-initialized class is the deliberate exception: it is published only
/// after its hidden factory has supplied every field.
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
        "a {s} starts before anything fills it and a function value has no zero: write ({s})?",
        .{ role, try self.typeName(part) },
    );
    return true;
}

/// A channel element must be sendable: nothing in its type graph may
/// be a class, a function value, weak storage, or a resource — the
/// worker boundary's own refusals, decided here by type where the
/// boundary decides them by graph (docs/THREADS.md).
pub fn refuseUnsendablePart(self: *Analyzer, part: Type, span: Span) Error!bool {
    const shapes_mod = @import("shapes.zig");
    const carried: [4]struct { kind: shapes_mod.Carried, said: []const u8 } = .{
        .{ .kind = .class, .said = "a class has identity one runtime owns" },
        .{ .kind = .function, .said = "a function value cannot cross workers" },
        .{ .kind = .weak, .said = "weak storage names one runtime's table" },
        .{ .kind = .resource, .said = "a resource belongs to the runtime that made it" },
    };
    for (carried) |sought| {
        if (try shapes_mod.carries(self, part, sought.kind)) {
            try self.fail(
                "luce.sema.channel",
                span,
                "channel[{s}] cannot cross workers: {s}",
                .{ try self.typeName(part), sought.said },
            );
            return true;
        }
    }
    return false;
}

/// Report a written type name that names nothing, offering the
/// closest of the builtin types and the structs this module can
/// see.  A misremembered `Str` or `Bolean` is the commonest of all
/// type errors and the cheapest to answer well.
fn failUnknownType(self: *Analyzer, module: usize, written: ast.TypeName) Error!void {
    const builtin_types = types.builtin_names;
    const prefix = self.modules[module].prefix;
    var suggestion = helpers.Suggestion.init(written.name);
    suggestion.offerAll(&builtin_types);
    for ([_]*const std.StringHashMapUnmanaged(u32){ &self.alias_names, &self.struct_names, &self.enum_names, &self.variant_names }) |declared| {
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
    var interfaces = self.interface_names.keyIterator();
    while (interfaces.next()) |key| {
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

/// The source declaration indexed by `layout` has one of two machine
/// meanings. Value structs travel as field runs; classes travel as ARC
/// object handles. Resolve that distinction once, at the nominal name.
pub fn nominalType(self: *Analyzer, layout: u32) Error!Type {
    if (!self.structs.items[layout].reference) return .{ .strukt = layout };
    return internHeapType(self, .{ .class = layout });
}

/// Intern one function signature and answer the type that names it.
pub fn internSignature(self: *Analyzer, signature: types.Signature) Error!Type {
    for (self.signatures.items, 0..) |existing, index| {
        if (existing.eql(signature)) return .{ .function = @intCast(index) };
    }
    try self.signatures.append(self.arena, signature);
    return .{ .function = @intCast(self.signatures.items.len - 1) };
}
