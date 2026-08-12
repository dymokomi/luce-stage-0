//! The entry: the four shapes a program may declare, and the one the
//! compiler builds for `luce test`.
//!
//! A program is `func main():` or `func main(args: list(string)):`,
//! each with an optional `-> !` — four shapes, checked by `check`
//! below, and there is no second entry *mode*: whatever the entry is,
//! it is one row of the function table that the runtime starts through
//! the published ABI.
//!
//! `luce test` is the same sentence said by the compiler instead of by
//! the source (docs/TESTING.md D3).  The runner discovers the file's
//! `func test_*()` declarations, hands their names down as
//! `CompileOptions.entry`, and `synthesize` writes the fourth shape —
//! `func main(args: list(string)) -> !` — whose body reads one name
//! out of `args` and calls exactly that test **by direct call**.  It is
//! built as ordinary AST and collected as an ordinary signature, so it
//! is checked by the same walk, lowered by the same pass, verified by
//! the same verifier and optimized by the same passes as anything a
//! person wrote: there is no second path through the compiler for it
//! to drift down.
//!
//! Why a static dispatch and not a table of function values: `func()`
//! and `func() -> !` are distinct value types (docs/FUNCTIONS.md S2),
//! so a `list` of tests is not a thing the type system can hold.  A
//! chain of direct calls is what the language can say, and it is what
//! the runner needs — one call per invocation, chosen by name.
//!
//! Free functions over `declarations.zig`'s `*Analyzer`, like every
//! other file in this stage.

const std = @import("std");
const source_mod = @import("../01_source.zig");
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");

const resolve = @import("resolve.zig");

const context = @import("context.zig");
const Error = context.Error;
const Span = source_mod.Span;
const Type = types.Type;
const Analyzer = @import("declarations.zig").Analyzer;

/// Settle which function the runtime starts, once every signature is
/// collected.  One of the two rules applies, never both.
pub fn settle(self: *Analyzer) Error!void {
    switch (self.options.entry) {
        .declared => try check(self),
        .tests => |names| try synthesize(self, names),
    }
}

// ---------------------------------------------------------------------------
// The declared entry
// ---------------------------------------------------------------------------

fn check(self: *Analyzer) Error!void {
    const index = self.function_names.get("main") orelse {
        try self.fail("luce.sema.main", .{ .start = 0, .end = 0 }, "missing func main():", .{});
        return;
    };
    self.entry_function = index;
    const info = self.functions.items[index];
    const declaration = info.declaration;
    // Four shapes are legal: `func main():` and
    // `func main(args: list(string)):`, each with or without `-> !`
    // — the mark is how a program says the world can stop it, and
    // loom reports what it raised (docs/FAILURE.md).  A program
    // that never reads a command line says nothing about one, which
    // is why the parameter is optional rather than Java's mandatory
    // ceremony (docs/METHODS.md).
    //
    // The name is free and the type is fixed: `args` is a binding
    // like any other, so there is no misspelling of it to diagnose.
    if (declaration.parameters.len > 1) {
        try self.fail(
            "luce.sema.main",
            declaration.parameters[1].span,
            "main takes at most one parameter, the command line; it has {d}",
            .{declaration.parameters.len},
        );
    } else if (declaration.parameters.len == 1) {
        const parameter = declaration.parameters[0];
        if (parameter.mode == .give) {
            // S13 says `give` appears at both ends, and the entry
            // has one end: the runtime is the caller and there is
            // no call site to say it back.
            try self.fail(
                "luce.sema.main",
                parameter.span,
                "main's parameter takes no verb; the runtime hands the list to main's scope [OWNERSHIP.md S44]",
                .{},
            );
        } else if (info.parameter_types.len == 1 and
            !isCommandLine(self, info.parameter_types[0]))
        {
            try self.fail(
                "luce.sema.main",
                parameter.type_name.span,
                "main's parameter is the command line and must be list(string); it is {s} here",
                .{try self.typeName(info.parameter_types[0])},
            );
        }
    }
    if (declaration.returnsSpan()) |written| {
        try self.fail(
            "luce.sema.main",
            written,
            "main returns nothing; use func main():, func main() -> !:, func main(args: list(string)):, or func main(args: list(string)) -> !:",
            .{},
        );
    }
}

/// Whether a type is the one shape the entry's parameter may have.
fn isCommandLine(self: *const Analyzer, of: Type) bool {
    const descriptor = self.heapOf(of) orelse return false;
    return descriptor == .list and descriptor.list == .string;
}

// ---------------------------------------------------------------------------
// The synthesized entry
// ---------------------------------------------------------------------------

/// The name of the synthesized entry's own parameter.  A local of the
/// synthesized body and nothing else — no source can see it, and it
/// shadows nothing, because file-scope names live in another namespace.
const selector_parameter = "args";

/// Write `func main(args: list(string)) -> !` over `names`, register
/// it, and make it the entry.
///
/// It is a row of the ordinary function table, so it is registered the
/// way a lambda is — appended with its settled signature and *not* put
/// in `function_names`.  Nothing may call it: the runtime starts it,
/// and a source `main` (which `luce test` ignores) keeps that name for
/// itself as an ordinary function nothing reaches.
///
/// Every call is spanned at the test's own declaration, so a trap
/// inside a test reports the entry frame at the line the test is
/// written on rather than at a position nobody wrote.
fn synthesize(self: *Analyzer, names: []const []const u8) Error!void {
    const nowhere: Span = .{ .start = 0, .end = 0 };
    // The synthesized body belongs to the root module — that is where
    // the tests are, and where its calls have to resolve — and the
    // root is the first module the graph loads (`compile/modules.zig`).
    const module: usize = 0;
    self.diagnostics.scope = self.modules[module].file;

    var statements: std.ArrayList(ast.Statement) = .empty;

    // `if len(args) != 1: error(...)` — the artifact runs one named
    // test per call, and says so when it is handed anything else.  Not
    // decoration: without it a bare run of the artifact meets
    // `index_bounds` on the line below and reports a trap about the
    // runner's contract as if it were the program's bug.
    const counted = try expression(self, .{ .call = .{
        .callee = "len",
        .arguments = try one(self, ast.Argument, .{
            .name = null,
            .value = try name(self, selector_parameter, nowhere),
            .span = nowhere,
        }),
        .span = nowhere,
    } });
    try statements.append(self.arena, .{ .conditional = .{
        .condition = try expression(self, .{ .binary = .{
            .op = .not_equal,
            .left = counted,
            .right = try expression(self, .{ .int_literal = .{ .text = "1", .span = nowhere } }),
            .span = nowhere,
        } }),
        .then_block = .{
            .statements = try one(self, ast.Statement, try raise(
                self,
                try text(self, "luce test: this artifact runs one named test per call", nowhere),
                nowhere,
            )),
            .span = nowhere,
        },
        .else_block = null,
        .span = nowhere,
    } });

    // One `if args[0] == "test_x": test_x(); return` per test, in the
    // order they were declared.  Flat rather than an `elif` chain, so
    // a file with a hundred tests is a hundred statements and not a
    // hundred levels of nesting for every later walk to descend.
    for (names) |wanted| {
        const declared = self.function_names.get(wanted);
        const at = if (declared) |index|
            self.functions.items[index].declaration.name_span
        else
            nowhere;
        // An unknown name is left to say so as an ordinary unresolved
        // call: the runner's discovery is what decides which functions
        // are tests, and this stage re-derives none of it.
        const fallible = if (declared) |index| self.functions.items[index].fallible else false;

        const called = try expression(self, .{ .call = .{
            .callee = wanted,
            .arguments = &.{},
            .span = at,
        } });
        const run = if (fallible)
            try expression(self, .{ .try_call = .{ .operand = called, .span = at } })
        else
            called;

        const body = try self.arena.alloc(ast.Statement, 2);
        body[0] = .{ .expression = .{ .value = run, .span = at } };
        body[1] = .{ .return_statement = .{ .values = &.{}, .span = at } };
        try statements.append(self.arena, .{ .conditional = .{
            .condition = try expression(self, .{ .binary = .{
                .op = .equal,
                .left = try selected(self, nowhere),
                .right = try text(self, wanted, at),
                .span = at,
            } }),
            .then_block = .{ .statements = body, .span = at },
            .else_block = null,
            .span = at,
        } });
    }

    // Nothing matched.  The runner only ever asks for a name it
    // discovered, so this is the artifact answering somebody who ran it
    // by hand — which is exactly when a sentence naming the name is
    // worth building.
    try statements.append(self.arena, try raise(self, try expression(self, .{ .binary = .{
        .op = .add,
        .left = try text(self, "luce test: no test named ", nowhere),
        .right = try selected(self, nowhere),
        .span = nowhere,
    } }), nowhere));

    const written = try self.arena.create(ast.FuncDecl);
    const element = try one(self, ast.TypeName, .{ .name = "string", .span = nowhere });
    written.* = .{
        .name = "main",
        .name_span = nowhere,
        .parameters = try one(self, ast.Parameter, .{
            .name = selector_parameter,
            .name_span = nowhere,
            .type_name = .{ .name = "list", .arguments = element, .span = nowhere },
            .span = nowhere,
        }),
        .fallible = true,
        .body = .{ .statements = try statements.toOwnedSlice(self.arena), .span = nowhere },
        .span = nowhere,
    };

    const command_line = (try resolve.resolveType(self, module, written.parameters[0].type_name)) orelse
        return;
    const index: u32 = @intCast(self.functions.items.len);
    try self.functions.append(self.arena, .{
        .declaration = written,
        .name = written.name,
        .module = module,
        .parameter_types = try one(self, Type, command_line),
        .parameter_modes = try one(self, ast.ParameterMode, .borrow),
        .parameter_defaults = try one(self, ?context.TypedConstant, null),
        .receiver = .not,
        .enclosing = null,
        .results = &.{},
        .channel = &.{},
        .return_type = .none,
        .fallible = true,
        .is_entry = true,
    });
    self.entry_function = index;
}

/// `error(message)` as a statement — how the synthesized entry says no.
fn raise(self: *Analyzer, message: *ast.Expression, at: Span) Error!ast.Statement {
    return .{ .expression = .{
        .value = try expression(self, .{ .call = .{
            .callee = "error",
            .arguments = try one(self, ast.Argument, .{
                .name = null,
                .value = message,
                .span = at,
            }),
            .span = at,
        } }),
        .span = at,
    } };
}

/// `args[0]` — the name the runner asked for.  A fresh node per use:
/// the walk reads a tree, and a shared node would be one subexpression
/// standing in several places at once.
fn selected(self: *Analyzer, at: Span) Error!*ast.Expression {
    return expression(self, .{ .index = .{
        .target = try name(self, selector_parameter, at),
        .indices = try one(self, *ast.Expression, try expression(
            self,
            .{ .int_literal = .{ .text = "0", .span = at } },
        )),
        .span = at,
    } });
}

fn name(self: *Analyzer, spelled: []const u8, at: Span) Error!*ast.Expression {
    return expression(self, .{ .name = .{ .text = spelled, .span = at } });
}

fn text(self: *Analyzer, decoded: []const u8, at: Span) Error!*ast.Expression {
    return expression(self, .{ .string_literal = .{ .decoded = decoded, .span = at } });
}

fn expression(self: *Analyzer, node: ast.Expression) Error!*ast.Expression {
    const made = try self.arena.create(ast.Expression);
    made.* = node;
    return made;
}

/// A one-element slice of `T`, arena-owned — what almost every field
/// of a synthesized node wants.
fn one(self: *Analyzer, comptime T: type, value: T) Error![]T {
    const made = try self.arena.alloc(T, 1);
    made[0] = value;
    return made;
}
