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
const source_mod = @import("../source.zig");
const ast = @import("../parse.zig").ast;
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
    var aliases = self.analyzer.alias_names.iterator();
    while (aliases.next()) |entry| {
        const info = self.analyzer.alias_decls.items[entry.value_ptr.*];
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

/// A module that is present in the project but not imported by this
/// file is neither an unknown name nor a value receiver.  Calls and
/// dotted value reads share this sentence, so a repair cannot depend
/// on whether the member happened to be followed by parentheses.
pub fn failUnimportedNamespace(self: *FunctionBuilder, name: []const u8, span: Span) Error!bool {
    for (self.analyzer.modules) |module| {
        if (module.binding.len == 0 or !std.mem.eql(u8, module.binding, name)) continue;
        try self.fail(
            "luce.sema.import",
            span,
            "unknown namespace {s}; import {s} to use it",
            .{ name, try naming.importSpelling(self.analyzer, name) },
        );
        return true;
    }
    return false;
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
            "pass it as a parameter, or write a struct with a method — state that travels with behavior is a struct",
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
    if (self.analyzer.alias_names.get(qualified)) |index| {
        const info = self.analyzer.alias_decls.items[index];
        const target = if (info.state == .ready)
            try self.analyzer.typeName(info.resolved)
        else
            "an unresolved type";
        try self.fail(
            "luce.sema.name",
            span,
            "{s} is a type alias for {s}, not a value; use it in a type annotation or constructor",
            .{ written, target },
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
    // A retired conversion spelling receives the same direct migration
    // answer as that spelling in a type annotation.
    if (types.retiredSpelling(written)) |now| {
        try self.fail(
            "luce.sema.type.retired",
            span,
            "{s} is retired; write {s}",
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
    var aliases = self.analyzer.alias_names.iterator();
    while (aliases.next()) |entry| {
        const info = self.analyzer.alias_decls.items[entry.value_ptr.*];
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
                    "two {s} values are not compared with {s}; match on each and compare what the arms carry",
                    .{ try self.analyzer.typeName(compared), operator },
                );
                return;
            }
            try self.fail(
                "luce.sema.union",
                span,
                "{s} is compared field by field and it reaches {s}, which is a union; match is the only door into one, " ++
                    "so {s} is refused here too — match on the member and compare what the arms carry",
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
                        "compare str(f) if the name is what you meant",
                    .{operator},
                );
                return;
            }
            try self.fail(
                "luce.sema.type",
                span,
                "{s} is compared field by field and it reaches {s}: a function value has no equality, because its type " ++
                    "cannot say which receiver it carries, so {s} has no honest answer — compare str(f) of the field " ++
                    "if the name is what you meant",
                .{ try self.analyzer.typeName(compared), try self.analyzer.typeName(found.part), operator },
            );
        },
        .weak => try self.fail(
            "luce.sema.weak.access",
            span,
            "{s} contains weak storage, whose public value is a liveness snapshot; {s} cannot compare hidden weak handles — read and compare the optional field explicitly",
            .{ try self.analyzer.typeName(compared), operator },
        ),
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
                        "and search that",
                    .{ method_name, element_name },
                );
                return;
            }
            try self.fail(
                "luce.sema.method",
                span,
                "{s} compares elements with ==, and {s} reaches {s}, which is a union: match is the only door into one, " ++
                    "so a list or an array of them cannot be searched — keep what identifies the member beside it, a name " ++
                    "or an enum, and search that",
                .{ method_name, element_name, part_name },
            );
        },
        .function => {
            if (!nested) {
                try self.fail(
                    "luce.sema.method",
                    span,
                    "a function value has no equality, so a list or an array of them cannot be searched; " ++
                        "keep what you meant to look for beside them — a name, an enum — and search that",
                    .{},
                );
                return;
            }
            try self.fail(
                "luce.sema.method",
                span,
                "{s} compares elements with ==, and {s} reaches {s}: a function value has no equality, because a function " ++
                    "type cannot say which receiver a value carries — keep what you meant to look for beside them, a name " ++
                    "or an enum, and search that",
                .{ method_name, element_name, part_name },
            );
        },
        .weak => try self.fail(
            "luce.sema.weak.access",
            span,
            "{s} compares elements with ==, but {s} contains weak storage whose value is a liveness snapshot; search a stable key or read the optional field explicitly",
            .{ method_name, element_name },
        ),
    }
}
