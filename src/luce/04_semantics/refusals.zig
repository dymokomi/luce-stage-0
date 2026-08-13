//! What this walk says when it says no.
//!
//! Two families of refusal that share one shape — decide the sentence,
//! offer the fix, and hand back an error — and that reach nothing of
//! the walker but its scopes and its project: the unknown name (what
//! was meant instead, whether the name is private, captured, a
//! namespace member, or a field spelled almost right) and the
//! ownership verb (what a value needs before it can be kept, why a
//! resource may not be copied, and what a `free` may not be written
//! on), together with the advice sentences both end in.
//!
//! They are a file because a diagnostic is a leaf: nothing here
//! decides anything the walk goes on to use, and the walk's own arms
//! read better with the paragraph of teaching prose lifted out of
//! them.  The interface is the `fail*` and `refuse*` verbs; each one
//! either reports and returns, or answers whether it reported.

const std = @import("std");
const source_mod = @import("../01_source.zig");
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");
const helpers = @import("helpers.zig");
const builtins_mod = @import("builtins.zig");
const builtins = builtins_mod.builtins;
const retired_builtins = builtins_mod.retired_builtins;
const context = @import("context.zig");
const Error = context.Error;
const Span = source_mod.Span;
const Type = types.Type;

const builder = @import("builder.zig");
const flow = @import("flow.zig");
const recorder = @import("recorder.zig");
const naming = @import("naming.zig");
const shapes = @import("shapes.zig");
const FunctionBuilder = builder.FunctionBuilder;
const Typed = builder.Typed;

/// The source-order operand batch around an ownership refusal.  A
/// move suggested for one operand must not make a later operand in
/// the same call unreadable (S10, S29).
pub const OwnershipBatch = struct {
    expressions: []const *ast.Expression,
    position: usize,
};

/// The name a declaration key is written as inside this module, or
/// null when it belongs to a module this one cannot see unqualified.
fn visibleName(self: *const FunctionBuilder, key: []const u8) ?[]const u8 {
    if (self.prefix.len == 0) return key;
    if (key.len <= self.prefix.len + 1) return null;
    if (!std.mem.startsWith(u8, key, self.prefix)) return null;
    if (key[self.prefix.len] != '.') return null;
    return key[self.prefix.len + 1 ..];
}

/// The declaration-level gate at every site a call resolves
/// (docs/VISIBILITY.md §1): a private function, or any member of a
/// private struct, is reachable from its own file and nowhere
/// else.  True when the call may proceed.  The refusal names the
/// withheld declaration and its module — private is never
/// "unknown" (D2), and it fires *after* existence is established,
/// which is what the code buys.
pub fn functionReachable(self: *FunctionBuilder, function_index: u32, span: Span) Error!bool {
    const info = self.analyzer.functions.items[function_index];
    if (info.module == self.module) return true;
    // A namespace function of a private struct — or of a private
    // enum — is reached through that name, and it is the name that
    // is withheld.
    if (info.enclosing) |owner| {
        const declaration = switch (owner) {
            .strukt => |index| self.analyzer.struct_decls.items[index].declaration.visibility,
            .enumeration => |reference| self.analyzer.enum_decls.items[reference.index].declaration.visibility,
            .variant => |index| self.analyzer.variant_decls.items[index].declaration.visibility,
        };
        if (declaration == .private) {
            try self.fail("luce.sema.private", span, "{s} is private to {s}", .{
                switch (owner) {
                    .strukt => |index| self.analyzer.struct_decls.items[index].declaration.name,
                    .enumeration => |reference| self.analyzer.enum_decls.items[reference.index].declaration.name,
                    .variant => |index| self.analyzer.variant_decls.items[index].declaration.name,
                },
                naming.moduleName(self.analyzer, info.module),
            });
            return false;
        }
    }
    if (info.declaration.visibility == .private) {
        try self.fail("luce.sema.private", span, "{s} is private to {s}", .{
            info.declaration.name,
            naming.moduleName(self.analyzer, info.module),
        });
        return false;
    }
    return true;
}

/// The field-level gate at every site a field is read, written, or
/// named (docs/VISIBILITY.md §1, §3).  Within the declaring module
/// the bit is never consulted.
pub fn fieldReachable(
    self: *FunctionBuilder,
    layout_index: u32,
    field_index: u32,
    span: Span,
) Error!bool {
    const info = self.analyzer.struct_decls.items[layout_index];
    if (info.module == self.module) return true;
    if (field_index >= info.field_visibility.len) return true;
    if (info.field_visibility[field_index] != .private) return true;
    try self.fail("luce.sema.private", span, "{s} of {s} is private to {s}", .{
        self.analyzer.structs.items[layout_index].fields[field_index].name,
        info.declaration.name,
        naming.moduleName(self.analyzer, info.module),
    });
    return false;
}

fn offerDeclarations(self: *FunctionBuilder, suggestion: *helpers.Suggestion) void {
    var functions = self.analyzer.function_names.iterator();
    while (functions.next()) |entry| {
        const info = self.analyzer.functions.items[entry.value_ptr.*];
        if (info.declaration.visibility == .private and info.module != self.module) continue;
        if (visibleName(self, entry.key_ptr.*)) |name| suggestion.offer(name);
    }
    var structs = self.analyzer.struct_names.iterator();
    while (structs.next()) |entry| {
        const info = self.analyzer.struct_decls.items[entry.value_ptr.*];
        if (info.declaration.visibility == .private and info.module != self.module) continue;
        if (visibleName(self, entry.key_ptr.*)) |name| suggestion.offer(name);
    }
    var constants = self.analyzer.constant_names.iterator();
    while (constants.next()) |entry| {
        const info = self.analyzer.constant_infos.items[entry.value_ptr.*];
        if (info.declaration.visibility == .private and info.module != self.module) continue;
        if (visibleName(self, entry.key_ptr.*)) |name| suggestion.offer(name);
    }
}

fn offerLocals(self: *FunctionBuilder, suggestion: *helpers.Suggestion) void {
    var index = self.scopes.items.len;
    while (index > 0) {
        index -= 1;
        var names = self.scopes.items[index].names.keyIterator();
        while (names.next()) |key| suggestion.offer(key.*);
    }
}

/// Report a bare name that resolved to nothing — unless it is a
/// name whose own declaration already failed, in which case the
/// error the reader needs is already reported and this one is
/// only noise.
pub fn failUnknownName(self: *FunctionBuilder, name: []const u8, span: Span) Error!void {
    if (self.undeclared.contains(name)) return;
    if (try failCapturedName(self, name, span)) return;
    if (std.mem.eql(u8, name, "self")) {
        if (self.static_member) {
            try self.fail(
                "luce.sema.self",
                span,
                "self is unavailable in a static function; remove static to make this a method",
                .{},
            );
        } else {
            try self.fail(
                "luce.sema.self",
                span,
                "self exists only inside a non-static struct or enum member",
                .{},
            );
        }
        return;
    }
    const qualified = try naming.qualify(self.analyzer, self.prefix, name);
    if (try failNotAValue(self, name, qualified, span)) return;
    var suggestion = helpers.Suggestion.init(name);
    offerLocals(self, &suggestion);
    offerDeclarations(self, &suggestion);
    if (suggestion.best()) |closest| {
        try self.fail("luce.sema.name", span, "unknown name {s}; did you mean {s}?", .{ name, closest });
        return;
    }
    try self.fail("luce.sema.name", span, "unknown name {s}", .{name});
}

/// **A lambda carries no environment** (docs/FUNCTIONS.md S3).
/// Inside the function a lambda became, a name that was a local
/// where the lambda was written is not unknown — it is out of
/// reach, and those are different sentences.  Both value position
/// (`n * scale`) and callee position (`predicate(n)`) ask this one
/// question, so neither falls through to a misleading unknown-name
/// diagnostic.
pub fn capturesName(self: *FunctionBuilder, name: []const u8) bool {
    // A lambda parameter or one of its own locals wins normally;
    // only a name that would have to come from the writing scope
    // is a capture.
    if (self.findLocal(name) != null) return false;
    if (self.enclosing_locals) |visible| {
        for (visible) |held| {
            if (std.mem.eql(u8, held.name, name)) return true;
        }
    }
    return false;
}

pub fn failCapturedName(self: *FunctionBuilder, name: []const u8, span: Span) Error!bool {
    if (!capturesName(self, name)) return false;
    try self.fail(
        "luce.sema.name",
        span,
        "a lambda carries no environment, and {s} belongs to the scope around it; " ++
            "pass it as a parameter, or write a struct with a method — state that travels with behavior is a struct [FUNCTIONS.md S3]",
        .{name},
    );
    return true;
}

/// A name in value position that names a declaration rather than a
/// value.  A function *is* a value where a function type is
/// expected (docs/FUNCTIONS.md S1), so what is left here is a bare
/// name where nothing said which shape it should wear — `let f =
/// helper`, `let x = math.seed` — and those are not *unknown
/// names*: saying so would deny a declaration the compiler has
/// already checked.  Answers what the name is and how to use it;
/// true when it reported.
pub fn failNotAValue(
    self: *FunctionBuilder,
    written: []const u8,
    qualified: []const u8,
    span: Span,
) Error!bool {
    if (self.analyzer.function_names.contains(qualified)) {
        try self.fail(
            "luce.sema.name",
            span,
            "{s} is a function; write {s}(...) to call it, or annotate the place it goes with the function type it should wear [FUNCTIONS.md]",
            .{ written, written },
        );
        return true;
    }
    if (self.analyzer.struct_names.contains(qualified)) {
        try self.fail(
            "luce.sema.name",
            span,
            "{s} is a struct, not a value; write {s}(field = ...) to build one",
            .{ written, written },
        );
        return true;
    }
    return false;
}

/// `math.seed`, `Words.classify` — a namespace member reached
/// without a call.  The namespace is real and its members are in
/// hand, so the answer names what the member is, or offers the
/// closest member there actually is.
///
/// `namespace` and `member` are spelled the way the author wrote
/// them; `joined` is the fully-qualified key those two resolve to,
/// which is what the declaration tables are keyed on.
pub fn failNamespaceMember(
    self: *FunctionBuilder,
    namespace: []const u8,
    member: []const u8,
    joined: []const u8,
    span: Span,
) Error!void {
    const written = try std.fmt.allocPrint(self.arena(), "{s}.{s}", .{ namespace, member });
    if (try failNotAValue(self, written, joined, span)) return;

    // Members of this namespace only: `math.sed` wants `seed`
    // offered, never a same-named function of another module — and
    // never a name the namespace withheld (VISIBILITY.md D2:
    // did-you-mean offers visible names only).
    const scope = joined[0 .. joined.len - member.len];
    var suggestion = helpers.Suggestion.init(member);
    {
        var entries = self.analyzer.function_names.iterator();
        while (entries.next()) |entry| {
            const tail = namespaceTail(scope, entry.key_ptr.*) orelse continue;
            const info = self.analyzer.functions.items[entry.value_ptr.*];
            if (info.declaration.visibility == .private and info.module != self.module) continue;
            suggestion.offer(tail);
        }
    }
    {
        var entries = self.analyzer.struct_names.iterator();
        while (entries.next()) |entry| {
            const tail = namespaceTail(scope, entry.key_ptr.*) orelse continue;
            const info = self.analyzer.struct_decls.items[entry.value_ptr.*];
            if (info.declaration.visibility == .private and info.module != self.module) continue;
            suggestion.offer(tail);
        }
    }
    {
        var entries = self.analyzer.constant_names.iterator();
        while (entries.next()) |entry| {
            const tail = namespaceTail(scope, entry.key_ptr.*) orelse continue;
            const info = self.analyzer.constant_infos.items[entry.value_ptr.*];
            if (info.declaration.visibility == .private and info.module != self.module) continue;
            suggestion.offer(tail);
        }
    }
    if (suggestion.best()) |closest| {
        try self.fail(
            "luce.sema.name",
            span,
            "{s} has no member {s}; did you mean {s}.{s}?",
            .{ namespace, member, namespace, closest },
        );
        return;
    }
    try self.fail("luce.sema.name", span, "{s} has no member {s}", .{ namespace, member });
}

/// The immediate member `key` names inside `scope` ("geo."), or
/// null when the key lives elsewhere or deeper.
fn namespaceTail(scope: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, key, scope)) return null;
    const tail = key[scope.len..];
    if (tail.len == 0 or std.mem.indexOfScalar(u8, tail, '.') != null) return null;
    return tail;
}

/// Remember that `name`'s declaration was abandoned, so its later
/// uses stay quiet.
pub fn forgetName(self: *FunctionBuilder, name: []const u8) Error!void {
    try self.undeclared.put(self.temporary(), name, {});
}

/// Report a call whose callee names no declaration, offering the
/// closest function or struct the reader could have meant.
pub fn failUnknownFunction(self: *FunctionBuilder, written: []const u8, span: Span) Error!void {
    if (try failCapturedName(self, written, span)) return;
    // A name the language used to spell is not a typo, and the
    // reader is owed the replacement rather than a guess at what
    // they might have meant.  Reached only once nothing else
    // resolved, because `arg` is an ordinary word now and a program
    // that declares one gets its own.
    for (retired_builtins) |gone| {
        if (!std.mem.eql(u8, written, gone.name)) continue;
        try self.fail("luce.sema.retired", span, "{s} was retired: {s}", .{ gone.name, gone.instead });
        return;
    }
    // A conversion named for the type it produces is spelled the
    // way that type is, and the types are lowercase now
    // (docs/TYPES.md D8): `Int(x)` is `long(x)`.
    if (types.retiredSpelling(written)) |now| {
        try self.fail(
            "luce.sema.call",
            span,
            "the builtin types are lowercase: {s} is written {s}",
            .{ written, now },
        );
        return;
    }
    var suggestion = helpers.Suggestion.init(written);
    var functions = self.analyzer.function_names.iterator();
    while (functions.next()) |entry| {
        const info = self.analyzer.functions.items[entry.value_ptr.*];
        if (info.declaration.visibility == .private and info.module != self.module) continue;
        if (visibleName(self, entry.key_ptr.*)) |name| suggestion.offer(name);
    }
    var structs = self.analyzer.struct_names.iterator();
    while (structs.next()) |entry| {
        const info = self.analyzer.struct_decls.items[entry.value_ptr.*];
        if (info.declaration.visibility == .private and info.module != self.module) continue;
        if (visibleName(self, entry.key_ptr.*)) |name| suggestion.offer(name);
    }
    if (suggestion.best()) |closest| {
        try self.fail("luce.sema.call", span, "unknown function {s}; did you mean {s}?", .{ written, closest });
        return;
    }
    try self.fail("luce.sema.call", span, "unknown function {s}", .{written});
}

/// Report a field a struct does not have, offering the closest one
/// it does.  A struct's fields are right there in the layout, so
/// there is never an excuse for this message not to help — and a
/// field withheld from this module is never offered (VISIBILITY.md
/// D2: did-you-mean offers visible names only).
pub fn failUnknownField(
    self: *FunctionBuilder,
    code: []const u8,
    layout_index: u32,
    field: []const u8,
    span: Span,
) Error!void {
    const layout = self.analyzer.structs.items[layout_index];
    const info = self.analyzer.struct_decls.items[layout_index];
    var suggestion = helpers.Suggestion.init(field);
    for (layout.fields, 0..) |candidate, index| {
        if (info.module != self.module and
            index < info.field_visibility.len and
            info.field_visibility[index] == .private) continue;
        suggestion.offer(candidate.name);
    }
    if (suggestion.best()) |closest| {
        try self.fail(code, span, "{s} has no field {s}; did you mean {s}?", .{ layout.name, field, closest });
        return;
    }
    try self.fail(code, span, "{s} has no field {s}", .{ layout.name, field });
}

/// Report a destination that keeps what it is handed but was
/// handed a bare name (S21).  `subject` says what the destination
/// is; `situations` are the OWNERSHIP.md numbers to quote.
///
/// The advice depends on the name.  "give NAME, or copy NAME" is
/// right for an owned binding and *wrong* for a borrowed
/// parameter, which can never be given at all (S12) — pointing a
/// reader at `give` there only earns them a second error one
/// keystroke later, which is exactly the loop good diagnostics
/// exist to break.
pub fn failNeedsOwnership(
    self: *FunctionBuilder,
    span: Span,
    subject: []const u8,
    value: *const ast.Expression,
    value_type: Type,
    situations: []const u8,
) Error!void {
    return failNeedsOwnershipIn(
        self,
        span,
        subject,
        value,
        value_type,
        situations,
        null,
    );
}

/// The batch-aware form of the ownership refusal.  All other
/// ownership advice remains identical; only the case where
/// give NAME would poison a later occurrence gets a different
/// sentence.
pub fn failNeedsOwnershipBatch(
    self: *FunctionBuilder,
    span: Span,
    subject: []const u8,
    value: *const ast.Expression,
    value_type: Type,
    situations: []const u8,
    expressions: []const *ast.Expression,
    position: usize,
) Error!void {
    return failNeedsOwnershipIn(
        self,
        span,
        subject,
        value,
        value_type,
        situations,
        .{ .expressions = expressions, .position = position },
    );
}

fn failNeedsOwnershipIn(
    self: *FunctionBuilder,
    span: Span,
    subject: []const u8,
    value: *const ast.Expression,
    value_type: Type,
    situations: []const u8,
    batch: ?OwnershipBatch,
) Error!void {
    if (batch) |whole| {
        if (laterBatchName(whole, value)) |name| {
            try self.fail(
                "luce.sema.own",
                span,
                "{s}; {s} is used again later in this operand batch, so writing give {s} here would poison that use — pass distinct owned values instead [OWNERSHIP.md S13, S14, {s}]",
                .{ subject, name, name, situations },
            );
            return;
        }
    }
    const carries_resource = try shapes.carries(self.analyzer, value_type, .resource);
    if (value_type == .optional) {
        if (carries_resource) {
            const advice = try resourceMoveAdvice(self, value);
            try self.fail(
                "luce.sema.own",
                span,
                "{s}; {s} may be absent and its payload carries a file or task that cannot be copied — prove the owning binding is present, then {s} [OWNERSHIP.md S31, S43, {s}]",
                .{ subject, try self.analyzer.typeName(value_type), advice, situations },
            );
        } else {
            try self.fail(
                "luce.sema.own",
                span,
                "{s}; {s} may be absent — test it first, then store something fresh, copy a narrowed view, or give a narrowed owning name [OWNERSHIP.md S21, S43, {s}]",
                .{ subject, try self.analyzer.typeName(value_type), situations },
            );
        }
        return;
    }
    if (value.* == .name) {
        if (self.findLocal(value.name.text)) |found| {
            const name = value.name.text;
            const outside_loop = self.declaredOutsideActiveLoop(found.depth);
            switch (found.info.class) {
                .borrow_param => {
                    if (outside_loop) {
                        if (carries_resource) {
                            try self.fail(
                                "luce.sema.own",
                                span,
                                "{s}; {s} comes from outside this loop and carries a file or task, so it cannot be moved or copied per iteration — create or receive an owned value inside each iteration, or redesign the handoff [OWNERSHIP.md S12, S30, S31, {s}]",
                                .{ subject, name, situations },
                            );
                        } else {
                            try self.fail(
                                "luce.sema.own",
                                span,
                                "{s}; {s} is borrowed from outside this loop — store copy {s}; moving it would poison the next iteration [OWNERSHIP.md S12, S30, {s}]",
                                .{ subject, name, name, situations },
                            );
                        }
                        return;
                    }
                    if (carries_resource) {
                        try self.fail(
                            "luce.sema.own",
                            span,
                            "{s}; {s} is a borrowed parameter and carries a file or task, so it can neither be given nor copied — change {s} to a give parameter and make each call site pass ownership (give NAME for an owning name; fresh values need no verb), then write give {s} here [OWNERSHIP.md S12, S13, S14, S31, {s}]",
                            .{ subject, name, name, name, situations },
                        );
                        return;
                    }
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "{s}; {s} is a borrowed parameter and can never be given away — store copy {s}, or take {s} as give in the signature [OWNERSHIP.md S12, {s}]",
                        .{ subject, name, name, name, situations },
                    );
                    return;
                },
                .inout_receiver => {
                    if (carries_resource) {
                        if (outside_loop) {
                            try self.fail(
                                "luce.sema.own",
                                span,
                                "{s}; self comes from outside this loop and carries a file or task, so it cannot be moved or copied per iteration — create or receive an owned value inside each iteration, or redesign the handoff [SELF.md D4, OWNERSHIP.md S12, S30, S31, {s}]",
                                .{ subject, situations },
                            );
                        } else {
                            try self.fail(
                                "luce.sema.own",
                                span,
                                "{s}; self is the caller's receiver and cannot be moved out or copied because it carries a file or task — take a separate give parameter [SELF.md D4, OWNERSHIP.md S12, S31, {s}]",
                                .{ subject, situations },
                            );
                        }
                        return;
                    }
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "{s}; self is the caller's receiver and cannot be moved out — store copy self [SELF.md D4, OWNERSHIP.md S12, {s}]",
                        .{ subject, situations },
                    );
                    return;
                },
                .alias => {
                    if (self.giveableOwnerNameFor(found.info)) |owner| {
                        if (carries_resource) {
                            try self.fail(
                                "luce.sema.own",
                                span,
                                "{s}; {s} aliases a resource graph it does not own — write give {s}, the owning binding; {s} cannot be copied [OWNERSHIP.md S8, S23, S31, {s}]",
                                .{ subject, name, owner, name, situations },
                            );
                            return;
                        }
                        try self.fail(
                            "luce.sema.own",
                            span,
                            "{s}; {s} aliases an object it does not own — store copy {s}, or write give {s}, the owning binding [OWNERSHIP.md S8, S23, {s}]",
                            .{ subject, name, name, owner, situations },
                        );
                        return;
                    }
                    if (carries_resource) {
                        try self.fail(
                            "luce.sema.own",
                            span,
                            "{s}; {s} aliases a resource graph it does not own; this borrowed view cannot be copied or moved — obtain an owned value from an ownership-returning operation or redesign the handoff [OWNERSHIP.md S8, S23, S31, {s}]",
                            .{ subject, name, situations },
                        );
                        return;
                    }
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "{s}; {s} aliases an object it does not own — store copy {s} [OWNERSHIP.md S8, S23, {s}]",
                        .{ subject, name, name, situations },
                    );
                    return;
                },
                .owned => {
                    if (outside_loop) {
                        if (carries_resource) {
                            try self.fail(
                                "luce.sema.own",
                                span,
                                "{s}; {s} is owned outside this loop and cannot be moved or copied per iteration — create or receive an owned value inside each iteration, or redesign the handoff [OWNERSHIP.md S30, S31, {s}]",
                                .{ subject, name, situations },
                            );
                        } else {
                            try self.fail(
                                "luce.sema.own",
                                span,
                                "{s}; {s} is owned outside this loop — store copy {s}; moving it would poison the next iteration [OWNERSHIP.md S30, {s}]",
                                .{ subject, name, name, situations },
                            );
                        }
                        return;
                    }
                    if (carries_resource) {
                        try self.fail(
                            "luce.sema.own",
                            span,
                            "{s}; write give {s} to hand it over — {s} carries a file or task and cannot be copied [OWNERSHIP.md {s}, S31]",
                            .{ subject, name, name, situations },
                        );
                        return;
                    }
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "{s}; write give {s} to hand it over, or copy {s} to keep your own [OWNERSHIP.md {s}]",
                        .{ subject, name, name, situations },
                    );
                    return;
                },
            }
        }
    }
    if (carries_resource) {
        try self.fail(
            "luce.sema.own",
            span,
            "{s}; this borrowed resource view cannot be copied or moved — obtain an owned value from an ownership-returning operation or redesign the handoff [OWNERSHIP.md {s}, S31]",
            .{ subject, situations },
        );
        return;
    }
    try self.fail(
        "luce.sema.own",
        span,
        "{s}; store something fresh, give NAME, or copy NAME [OWNERSHIP.md {s}]",
        .{ subject, situations },
    );
}

/// Return the name of a direct binding occurrence in the source-level
/// wrappers that can still be repaired as one move.  Calls and
/// containers are intentionally not searched through: their ownership
/// effects are not known from syntax alone.
fn directBatchName(expression: *const ast.Expression) ?[]const u8 {
    return switch (expression.*) {
        .name => |name| name.text,
        .give => |given| if (given.operand.* == .name) given.operand.name.text else null,
        .copy => |copied| if (copied.operand.* == .name) copied.operand.name.text else null,
        else => null,
    };
}

fn laterBatchName(batch: OwnershipBatch, value: *const ast.Expression) ?[]const u8 {
    const current = directBatchName(value) orelse return null;
    if (batch.position + 1 >= batch.expressions.len) return null;
    for (batch.expressions[batch.position + 1 ..]) |later| {
        if (directBatchName(later)) |name| {
            if (std.mem.eql(u8, current, name)) return current;
        }
    }
    return null;
}

/// A move spelling that is actually available for a resource graph.
/// `copy` is never one; `give` is offered only for a live owning
/// binding, while a borrow or alias names the ownership change that
/// must happen first (S12, S23, S31).
fn resourceMoveAdvice(self: *FunctionBuilder, expression: *const ast.Expression) Error![]const u8 {
    if (expression.* != .name) {
        if (try self.yieldsOwnership(expression)) {
            return "remove copy; this expression already yields an owned resource graph";
        }
        return "this borrowed view cannot be copied or moved; obtain an owned value from an ownership-returning operation or redesign the handoff";
    }
    const name = expression.name.text;
    const found = self.findLocal(name) orelse
        return "obtain an owned value from an ownership-returning operation or redesign the handoff";
    return switch (found.info.class) {
        .owned => if (self.declaredOutsideActiveLoop(found.depth))
            "this resource is owned outside the active loop; create or receive an owned value inside each iteration, or redesign the handoff"
        else
            try std.fmt.allocPrint(
                self.arena(),
                "write give {s} to move its owning binding instead",
                .{name},
            ),
        .borrow_param => if (self.declaredOutsideActiveLoop(found.depth))
            "this resource is borrowed from outside the active loop; create or receive an owned value inside each iteration, or redesign the handoff"
        else
            try std.fmt.allocPrint(
                self.arena(),
                "{s} is borrowed; change it to a give parameter and make each call site pass ownership (give NAME for an owning name; fresh values need no verb), then write give {s} at this handoff",
                .{ name, name },
            ),
        .inout_receiver => if (self.declaredOutsideActiveLoop(found.depth))
            "self comes from outside the active loop; create or receive an owned value inside each iteration, or redesign the handoff"
        else
            "self is the caller's receiver; pass the resource as a separate give parameter instead",
        .alias => if (self.giveableOwnerNameFor(found.info)) |owner|
            try std.fmt.allocPrint(
                self.arena(),
                "{s} is an alias; write give {s}, its owning binding, instead",
                .{ name, owner },
            )
        else
            try std.fmt.allocPrint(
                self.arena(),
                "{s} is an alias; this borrowed view cannot be copied or moved — obtain an owned value from an ownership-returning operation or redesign the handoff",
                .{name},
            ),
    };
}

/// `copy` can appear either where the result is merely read or
/// where the surrounding operation intends to keep it.  Advice
/// that blindly says `give NAME` is therefore wrong for
/// `inspect(copy NAME)`: `inspect` may be a borrowing call.  The
/// repair stated here is valid in either context.  Removing copy
/// preserves the existing borrow; an ownership-taking context must
/// instead receive a distinct owned graph through its own legal
/// handoff (S12, S21, S31).
pub fn resourceCopyAdvice(self: *FunctionBuilder, expression: *const ast.Expression) Error![]const u8 {
    if (expression.* == .give) {
        return "this spelling gives before it copies; in a borrowing context remove both give and copy, while an ownership-taking context removes copy only";
    }
    if (try self.yieldsOwnership(expression)) {
        return "remove copy; this expression already yields an owned resource graph";
    }
    if (expression.* == .name) {
        if (self.findLocal(expression.name.text)) |found| {
            if (found.info.class == .alias and self.ownerNameFor(found.info) == null) {
                return try std.fmt.allocPrint(
                    self.arena(),
                    "remove copy only if {s} still names a live borrowed view; if its owner was replaced or this site must own the result, obtain a distinct owned graph or redesign the handoff",
                    .{expression.name.text},
                );
            }
        }
        return try std.fmt.allocPrint(
            self.arena(),
            "remove copy to use or borrow {s}; if the surrounding site must take ownership, supply a distinct owned graph or redesign the handoff",
            .{expression.name.text},
        );
    }
    return "remove copy to use this borrowed view; if the surrounding site must take ownership, obtain a distinct owned graph from an ownership-returning operation or redesign the handoff";
}

/// `free` is not an ownership-taking destination for an expression:
/// it deliberately releases one *binding*.  Diagnose a nested `give`
/// before lowering it, otherwise `free(give view)` first teaches a
/// handoff spelling and only the repaired program explains that free
/// takes a bare owner (S6, S8).  `copy` must be lowered normally so an
/// unknown name, an illegal value copy, or a non-copyable resource
/// keeps its own earlier diagnostic.  False leaves ordinary names and
/// unrelated expressions to free's type/name checks below.
pub fn refuseFreeVerb(
    self: *FunctionBuilder,
    expression: *const ast.Expression,
    span: Span,
) Error!bool {
    if (expression.* != .give) return false;

    const operand = expression.give.operand;
    if (operand.* != .name) {
        try self.fail(
            "luce.sema.own",
            span,
            "free(give EXPR) has no legal verb stack — remove the whole call, or bind a direct freeable handle and write free(NAME); carrying structs and borrowed views are released by their owner or scope [OWNERSHIP.md S6, S10, S31]",
            .{},
        );
        return true;
    }
    const name = operand.name.text;
    const found = self.findLocal(name) orelse return false;
    const info = found.info;
    if (!info.carries or info.poisoned != null) return false;
    const local_type = recorder.localType(self, info.local);
    const freeable = local_type == .heap or
        (local_type == .optional and local_type.optional.asType() == .heap);
    if (!freeable) {
        try self.fail(
            "luce.sema.own",
            span,
            "a carrying struct cannot be released through free(give NAME) — remove the whole call and let this value's scope release it, or move it to an ownership-taking site [OWNERSHIP.md S6, S31]",
            .{},
        );
        return true;
    }
    const may_be_absent = local_type == .optional and !flow.isNarrowed(self, info.local);
    switch (info.class) {
        .owned => {
            if (self.declaredOutsideActiveLoop(found.depth)) {
                try self.fail(
                    "luce.sema.own",
                    span,
                    "free names its owner directly, but {s} is declared outside this loop and cannot be released per iteration — let its outer scope release it, or create the owner inside the loop [OWNERSHIP.md S6, S30]",
                    .{name},
                );
            } else if (may_be_absent) {
                try self.fail(
                    "luce.sema.own",
                    span,
                    "{s} may be absent; prove {s} is present, then write free({s}) directly without give [OWNERSHIP.md S6, S43]",
                    .{ try self.analyzer.typeName(local_type), name, name },
                );
            } else {
                try self.fail(
                    "luce.sema.own",
                    span,
                    "free names its owner directly; remove give and write free({s}) [OWNERSHIP.md S6, S10]",
                    .{name},
                );
            }
        },
        .borrow_param => try self.fail(
            "luce.sema.own",
            span,
            "{s} is borrowed, so neither give nor free may release it; let its caller-owned scope release the resource [OWNERSHIP.md S6, S12]",
            .{name},
        ),
        .inout_receiver => try self.fail(
            "luce.sema.own",
            span,
            "self is the caller's receiver, so neither give nor free may release it; let the caller's scope release it [SELF.md D4, OWNERSHIP.md S6, S12]",
            .{},
        ),
        .alias => {
            if (self.ownerNameFor(info)) |owner| {
                const owning = self.findLocal(owner).?;
                const owner_type = recorder.localType(self, owning.info.local);
                if (self.declaredOutsideActiveLoop(owning.depth)) {
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "{s} is only an alias and its owner {s} lives outside this loop; neither may be released per iteration — let the outer scope release it [OWNERSHIP.md S6, S8, S23, S30]",
                        .{ name, owner },
                    );
                } else if (owner_type == .optional and !flow.isNarrowed(self, owning.info.local)) {
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "{s} is only an alias and its owner {s} is not proven present — prove the owning binding is present, then write free({s}) directly without give [OWNERSHIP.md S6, S8, S23, S43]",
                        .{ name, owner, owner },
                    );
                } else {
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "{s} is only an alias; free names the live owner directly — write free({s}), without give [OWNERSHIP.md S6, S8, S23]",
                        .{ name, owner },
                    );
                }
            } else {
                try self.fail(
                    "luce.sema.own",
                    span,
                    "{s} is a borrowed view with no giveable owner here; neither give nor free may release it — obtain the owning binding or redesign the lifetime [OWNERSHIP.md S6, S8, S23, S30]",
                    .{name},
                );
            }
        },
    }
    return true;
}

// Absence ---------------------------------------------------------------

/// The advice a `T?` earns when it turns up where a `T` belongs —
/// the message the whole feature is judged by, so it names the two
/// ways out and the name to apply them to.  Empty when the type is
/// not optional, so every caller can end with one `{s}` and say
/// nothing extra when there is nothing extra to say.
///
/// Only a *local* narrows (Dart's rule, and for Dart's reason: a
/// field or an element can change between the test and the use),
/// so anything else is told to bind a name first.
pub fn absenceAdvice(self: *FunctionBuilder, of: Type, from: ?*const ast.Expression) Error![]const u8 {
    if (of != .optional) return "";
    const named: ?[]const u8 = named: {
        const expression = from orelse break :named null;
        if (expression.* != .name) break :named null;
        if (self.findLocal(expression.name.text) == null) break :named null;
        break :named expression.name.text;
    };
    if (named) |name| {
        return std.fmt.allocPrint(
            self.arena(),
            "; test it first (if {s} != none:) or supply a fallback ({s} else …)",
            .{ name, name },
        );
    }
    return std.fmt.allocPrint(
        self.arena(),
        "; bind it to a name and test that (let x = …, then if x != none:), or supply a fallback (… else …)",
        .{},
    );
}

/// The advice a number earns when it turns up where a *narrower*
/// number belongs.  Narrowing is implicit in no direction and no
/// context (docs/TYPES.md §2), and a mismatch that says only that
/// leaves the reader to guess whether there is a way across at
/// all — there is, spelled with the name of the type it produces.
///
/// Empty for every pair that is not a numeric narrowing, so a
/// caller may append it beside `absenceAdvice` and say nothing
/// extra when there is nothing extra to say.
pub fn narrowingAdvice(self: *FunctionBuilder, expected: Type, actual: Type) Error![]const u8 {
    if (!expected.isNumeric() or !actual.isNumeric()) return "";
    if (actual.widensTo(expected)) return "";
    return std.fmt.allocPrint(
        self.arena(),
        "; narrowing is never implicit — write {s}(…)",
        .{try self.analyzer.typeName(expected)},
    );
}

/// What to say after a type mismatch: absence first, because a
/// missing value is a different mistake from a wrong width and the
/// reader has to fix it first, then the narrowing that has a
/// constructor to spell it.
pub fn mismatchAdvice(
    self: *FunctionBuilder,
    expected: Type,
    actual: Type,
    from: ?*const ast.Expression,
) Error![]const u8 {
    const absence = try absenceAdvice(self, actual, from);
    if (absence.len != 0) return absence;
    return narrowingAdvice(self, expected, actual);
}

/// The name behind an expression that is a `T?` the flow analysis
/// has already proved present — so a second test, or a fallback,
/// is dead code the reader should be told about rather than left
/// to wonder at "long is always there".
pub fn narrowedName(self: *FunctionBuilder, expression: *const ast.Expression) ?[]const u8 {
    if (expression.* != .name) return null;
    const found = self.findLocal(expression.name.text) orelse return null;
    if (recorder.localType(self, found.info.local) != .optional) return null;
    if (!flow.isNarrowed(self, found.info.local)) return null;
    return expression.name.text;
}

/// Report a `T?` standing where a `T` is required.  `situation`
/// says what wanted the value, in the reader's words.
pub fn failAbsence(
    self: *FunctionBuilder,
    span: Span,
    situation: []const u8,
    of: Type,
    from: ?*const ast.Expression,
) Error!void {
    try self.fail("luce.sema.absent", span, "{s} needs {s}, but this is {s}{s}", .{
        situation,
        try self.analyzer.typeName(of.held().?),
        try self.analyzer.typeName(of),
        try absenceAdvice(self, of, from),
    });
}

/// True after reporting, when `value` is optional and the place it
/// stands in is not.  The one call every operation that needs a
/// real value makes before it looks at the type any further.
pub fn refusesAbsence(
    self: *FunctionBuilder,
    value: Typed,
    situation: []const u8,
    span: Span,
    from: ?*const ast.Expression,
) Error!bool {
    if (value.value_type != .optional) return false;
    try failAbsence(self, span, situation, value.value_type, from);
    return true;
}

// -- what `==` cannot answer, wherever it is asked -------------------

/// Report an `==` or `!=` whose operands reach something equality has
/// no answer for (`shapes.incomparablePart`).
///
/// **The refusal is about the whole compared value, not its outermost
/// tag.**  A struct's `==` is field-by-field `==`, so `Cell == Cell`
/// where `Cell` holds a union is the comparison UNION.md D16 refuses,
/// and one whose field holds a function value is the comparison
/// BINDING.md D6 refuses — reached through a wrapper the reader never
/// thought of as comparing a union or a function.  Each sentence names
/// the part that answered, so the reader who wrote `a == b` on two
/// plain-looking structs is told which field to look at.
pub fn failIncomparable(
    self: *FunctionBuilder,
    found: shapes.Incomparable,
    compared: Type,
    operator: []const u8,
    span: Span,
) Error!void {
    const nested = !found.part.eql(compared);
    switch (found.reason) {
        .variant => {
            if (!nested) {
                try self.fail(
                    "luce.sema.union",
                    span,
                    "two {s} values are not compared with {s}; match on each and compare what the arms carry [UNION.md D16]",
                    .{ try self.analyzer.typeName(compared), operator },
                );
                return;
            }
            try self.fail(
                "luce.sema.union",
                span,
                "{s} is compared field by field and it reaches {s}, which is a union; match is the only door into one, " ++
                    "so {s} is refused here too — match on the member and compare what the arms carry [UNION.md D16]",
                .{ try self.analyzer.typeName(compared), try self.analyzer.typeName(found.part), operator },
            );
        },
        .function => {
            if (!nested) {
                try self.fail(
                    "luce.sema.type",
                    span,
                    "a function value is the function it names and the receiver it may carry, and its type cannot say which; " ++
                        "two values of one method with different receivers are different workers, so {s} has no honest answer — " ++
                        "compare string(f) if the name is what you meant [BINDING.md D6]",
                    .{operator},
                );
                return;
            }
            try self.fail(
                "luce.sema.type",
                span,
                "{s} is compared field by field and it reaches {s}: a function value has no equality, because its type " ++
                    "cannot say which receiver it carries, so {s} has no honest answer — compare string(f) of the field " ++
                    "if the name is what you meant [BINDING.md D6]",
                .{ try self.analyzer.typeName(compared), try self.analyzer.typeName(found.part), operator },
            );
        },
    }
}

/// Report an `xs.find(v)` or `xs.contains(v)` whose elements reach
/// something equality has no answer for.
///
/// Both look with `==`, so they are `failIncomparable`'s question in
/// another spelling and they must refuse exactly what it refuses —
/// which is what stopped being true when the test asked the element's
/// own tag: a `list(Button)` whose `Button` holds a function value
/// slipped through into the runtime's comparator, which has no
/// sentence to say.  The sentence names the element, what it reaches,
/// and the one move that works: search something that does compare.
pub fn failUnsearchable(
    self: *FunctionBuilder,
    found: shapes.Incomparable,
    element: Type,
    method_name: []const u8,
    span: Span,
) Error!void {
    // The element type and the part that answered are printed
    // separately rather than joined, because an element that *is* the
    // problem would otherwise be named twice in one sentence.
    const element_name = try self.analyzer.typeName(element);
    const part_name = try self.analyzer.typeName(found.part);
    const nested = !found.part.eql(element);
    switch (found.reason) {
        .variant => {
            if (!nested) {
                try self.fail(
                    "luce.sema.method",
                    span,
                    "{s} compares elements with ==, and {s} is a union: match is the only door into one, so a list or an " ++
                        "array of them cannot be searched — keep what identifies the member beside it, a name or an enum, " ++
                        "and search that [UNION.md D16]",
                    .{ method_name, element_name },
                );
                return;
            }
            try self.fail(
                "luce.sema.method",
                span,
                "{s} compares elements with ==, and {s} reaches {s}, which is a union: match is the only door into one, " ++
                    "so a list or an array of them cannot be searched — keep what identifies the member beside it, a name " ++
                    "or an enum, and search that [UNION.md D16]",
                .{ method_name, element_name, part_name },
            );
        },
        .function => {
            if (!nested) {
                try self.fail(
                    "luce.sema.method",
                    span,
                    "a function value has no equality, so a list or an array of them cannot be searched; " ++
                        "keep what you meant to look for beside them — a name, an enum — and search that [BINDING.md D6]",
                    .{},
                );
                return;
            }
            try self.fail(
                "luce.sema.method",
                span,
                "{s} compares elements with ==, and {s} reaches {s}: a function value has no equality, because a function " ++
                    "type cannot say which receiver a value carries — keep what you meant to look for beside them, a name " ++
                    "or an enum, and search that [BINDING.md D6]",
                .{ method_name, element_name, part_name },
            );
        },
    }
}
