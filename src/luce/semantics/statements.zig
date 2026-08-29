//! The statement walk: every form a body is a sequence of.
//!
//! Blocks and the reachability rule, declarations and bindings, the
//! destructuring shapes, `match` over enums and variants, the control
//! flow (`if`, `while`, the two `for`s, `break`, `continue`) and
//! `return` with the ownership questions returning asks — may this
//! value leave, does it name a borrowed root, does the graph it leaves
//! in contain the thing it was given from.
//!
//! It is a file because a statement is where this walk's scopes, its
//! loops and its ledger all move at once: entering one opens a scope
//! and a recording frame, leaving one closes both and flushes the
//! temporaries.  Its interface is `lowerBlock` — pass one's entry to
//! the whole walk — and the one arm per statement kind below it.

const std = @import("std");
const source_mod = @import("../source.zig");
const ast = @import("../parse.zig").ast;
const types = @import("../support/types.zig");
const mir = @import("../mir.zig");
const helpers = @import("helpers.zig");
const nodes = @import("../hir.zig").nodes;
const effects = @import("effects.zig");
const builtins_mod = @import("builtins.zig");
const builtins = builtins_mod.builtins;
const context = @import("context.zig");
const Analyzer = @import("declarations.zig").Analyzer;
const LocalInfo = context.LocalInfo;
const Error = context.Error;
const Span = source_mod.Span;
const Type = types.Type;
const StructLayout = types.StructLayout;
const LocalId = mir.LocalId;

const assign = @import("assign.zig");
const builder = @import("builder.zig");
const closures = @import("closures.zig");
const flow = @import("flow.zig");
const initializers = @import("initializers.zig");
const ledger = @import("ledger.zig");
const recorder = @import("recorder.zig");
const refusals = @import("refusals.zig");
const naming = @import("naming.zig");
const resolve = @import("resolve.zig");
const shapes = @import("shapes.zig");
const signatures = @import("signatures.zig");
const FunctionBuilder = builder.FunctionBuilder;
const StorageClass = builder.StorageClass;
const Typed = builder.Typed;

pub fn lowerBlock(self: *FunctionBuilder, block: ast.Block) Error!void {
    const initializer_body = self.initializer != null and !self.initializer.?.prelude_done;
    try self.pushScope();
    try recorder.openStatementFrame(self);
    if (initializer_body) try initializers.lowerPrelude(self, block.span);
    try refuseUnreachable(self, block);
    for (block.statements) |statement| {
        // Fresh objects nothing adopted die with their statement
        // (S3); the release is a no-op for everything adopted.
        const temps_floor = self.temps.items.len;
        const recorded_floor = recorder.recordedStatementCount(self);
        try lowerStatement(self, statement);
        ledger.flushTemps(self, temps_floor);
        // A statement that recorded nothing — a diagnostic
        // abandoned it — is a gap; a gapped body never reaches
        // `hir.lower`, because the driver stops at diagnostics
        // (nodes.Body.gaps).
        if (recorder.recordedStatementCount(self) == recorded_floor) self.recorded_gaps += 1;
    }
    if (initializer_body and !helpers.alwaysExits(block)) {
        try initializers.lowerReturn(self, block.span);
    }
    self.recorded_block = try recorder.closeStatementFrame(self, block.span);
    self.popScope();
}

/// A statement below one that never comes back cannot run, and the
/// reader wrote it believing it does.
///
/// **Why this is a refusal and not a tolerated wart.**  Luce has
/// one severity: every diagnostic stops the compile, because a
/// warning is a rule the language did not commit to
/// (`support/diagnostics.zig`).  So the only question is which side
/// of the line this falls on, and the language already draws that
/// line: it refuses `a < b < c` and `not a == b` because the way
/// they read and the way they run disagree, and it *accepts* an
/// unused local, which is merely redundant — the program means what
/// it says and does what it says.  Unreachable code is the first
/// kind, not the second.  A statement after `return` is one the
/// author believes runs, and it never does.
///
/// Only the first is reported: one terminator, one mistake, however
/// many lines it stranded.
fn refuseUnreachable(self: *FunctionBuilder, block: ast.Block) Error!void {
    for (block.statements, 0..) |statement, index| {
        if (index + 1 == block.statements.len) return;
        const leaves = helpers.exitingStatement(statement) orelse continue;
        const stranded = block.statements[index + 1];
        const at = self.analyzer.diagnostics.sources.place(
            self.analyzer.diagnostics.scope,
            statement.span().start,
        );
        return self.fail(
            "luce.sema.unreachable",
            stranded.span(),
            "this cannot run: the {s} on line {d} leaves the block first; delete it, or move it above the {s}",
            .{ leaves, at.line, leaves },
        );
    }
}

fn lowerStatement(self: *FunctionBuilder, statement: ast.Statement) Error!void {
    switch (statement) {
        .let => |binding| try lowerBinding(
            self,
            binding.name,
            binding.name_span,
            binding.annotation,
            binding.value,
            false,
            false,
            binding.span,
        ),
        .variable => |binding| {
            if (binding.value) |value| {
                try lowerBinding(
                    self,
                    binding.name,
                    binding.name_span,
                    binding.annotation,
                    value,
                    true,
                    binding.weak,
                    binding.span,
                );
            } else {
                try lowerLateDeclaration(
                    self,
                    binding.name,
                    binding.name_span,
                    binding.annotation.?,
                    binding.weak,
                    binding.span,
                );
            }
        },
        .destructure => |bind| try lowerDestructure(self, bind),
        .assign => |assigned| try assign.lowerAssign(self, assigned),
        .assign_many => |assigned| try lowerAssignMany(self, assigned),
        .conditional => |conditional| try lowerConditional(self, conditional),
        .while_loop => |loop| try lowerWhile(self, loop),
        .for_range => |loop| try lowerForRange(self, loop),
        .for_each => |loop| try lowerForEach(self, loop),
        .return_statement => |returned| try lowerReturn(self, returned),
        .break_statement => |broke| {
            if (self.loops.items.len == 0) {
                try self.fail("luce.sema.loop", broke.span, "break outside a loop", .{});
                return;
            }
            const frame = self.loops.items[self.loops.items.len - 1];
            // Early exits unwind what the scopes they leave still
            // own (S4) — recorded as the frame's two depths, from
            // which lower emits the releases and the jump.
            try recorder.recordStatement(self, .{ .break_ = .{
                .unwind = @intCast(self.scopes.items.len - frame.scope_depth),
                .temps_floor = @intCast(frame.temps_depth),
                .span = broke.span,
            } });
        },
        .continue_statement => |continued| {
            if (self.loops.items.len == 0) {
                try self.fail("luce.sema.loop", continued.span, "continue outside a loop", .{});
                return;
            }
            const frame = self.loops.items[self.loops.items.len - 1];
            try recorder.recordStatement(self, .{ .continue_ = .{
                .unwind = @intCast(self.scopes.items.len - frame.scope_depth),
                .temps_floor = @intCast(frame.temps_depth),
                .span = continued.span,
            } });
        },
        .pass_statement => |marker| {
            // A no-op that still records something: an empty block
            // scope. Recording nothing would read as a gap (a
            // diagnostic abandoned the statement, lowerBlock's
            // recorded_gaps rule), so `pass` records a real statement
            // that lowers to an empty sequence and falls through.
            try recorder.recordStatement(self, .{ .block = .{
                .statements = &.{},
                .releases = &.{},
                .span = marker.span,
            } });
        },
        .expression => |expression| {
            if (try self.lowerExpression(expression.value, true)) |value| {
                try recorder.recordStatement(self, .{ .expression = .{
                    .value = value.node,
                    .span = expression.span,
                } });
            }
        },
        .guarded => |guarded| try lowerGuarded(self, guarded),
        .match => |matched| try lowerMatch(self, matched),
    }
}

/// `match m:` — dispatch over an enum (docs/ENUMS.md R1).
///
/// **The lowering is the compare-and-branch tree an `elif` chain
/// would have been**, which is the point: the statement buys the
/// *checking* — every member named, none named twice, nothing named
/// that is not a member — and pays nothing for it at run time,
/// because LLVM turns a chain of equalities on one value into the
/// switch it already knows how to make.
///
/// **With every member named, the last arm is the fallthrough.**  An
/// enum's one promise is that every value of it is a member: the
/// only ways to make one are a member name and `Method(n)`, which
/// answers `Method?`.  So the final comparison would be a test that
/// can only succeed, and nothing traps here — there is no case left
/// for a trap to be about.
pub fn lowerMatch(self: *FunctionBuilder, matched: ast.Match) Error!void {
    const temps_floor = self.temps.items.len;
    const scrutinee = (try self.lowerExpression(matched.scrutinee, false)) orelse return;
    if (scrutinee.value_type == .variant) {
        return lowerVariantMatch(self, matched, scrutinee, temps_floor);
    }
    if (scrutinee.value_type.isInteger() or scrutinee.value_type == .char or
        scrutinee.value_type == .str or scrutinee.value_type == .boolean)
    {
        return lowerValueMatch(self, matched, scrutinee, temps_floor);
    }
    if (scrutinee.value_type.isFloating()) {
        try self.fail(
            "luce.sema.match",
            matched.scrutinee.span(),
            "a float never matches a literal exactly; chain if and elif with the tolerance the comparison deserves",
            .{},
        );
        return;
    }
    if (scrutinee.value_type != .enumeration) {
        try self.fail(
            "luce.sema.match",
            matched.scrutinee.span(),
            "match dispatches over an enum, a union, or a scalar value — an integer, char, str, or bool — and {s} is none of these{s}",
            .{
                try self.analyzer.typeName(scrutinee.value_type),
                try refusals.absenceAdvice(self, scrutinee.value_type, matched.scrutinee),
            },
        );
        return;
    }
    const reference = scrutinee.value_type.enumeration;
    const declared = self.analyzer.enums.items[reference.index];

    // Which members each arm names, and which members were named:
    // both are needed before anything is lowered, because whether
    // the *last* arm is a comparison or the fallthrough depends on
    // the whole set.  An arm may name several members at once
    // (`go, stop:`); the comma form arrives as `arm.values`, each a
    // bare name, and a single member is the one-name `arm.name` form.
    const chosen = try self.temporary().alloc([]u32, matched.arms.len);
    defer {
        for (chosen) |list| self.temporary().free(list);
        self.temporary().free(chosen);
    }
    @memset(chosen, &.{});
    const covered = try self.temporary().alloc(bool, declared.members.len);
    defer self.temporary().free(covered);
    @memset(covered, false);
    var usable = true;
    var any_multi = false;
    for (matched.arms, chosen) |arm, *slot| {
        // `go, stop:` — several members behind commas.  Each comes
        // through the value-pattern path as a bare name with no range;
        // anything else there is a literal arm, which belongs to a
        // match over a value, not over an enum.
        if (arm.values.len != 0) {
            const members = try self.temporary().alloc(u32, arm.values.len);
            var ok = true;
            for (arm.values, members) |pattern, *at| {
                if (pattern.high != null or pattern.low.* != .name) {
                    try self.fail(
                        "luce.sema.match",
                        pattern.span,
                        "{s} dispatches by member name; a literal arm belongs to a match over a value",
                        .{declared.name},
                    );
                    ok = false;
                    break;
                }
                const member = declared.findMember(pattern.low.name.text) orelse {
                    try failUnknownMember(self, declared, pattern.low.name.text, pattern.low.name.span);
                    ok = false;
                    break;
                };
                if (covered[member]) {
                    try self.fail(
                        "luce.sema.match",
                        pattern.span,
                        "{s} already has an arm in this match",
                        .{pattern.low.name.text},
                    );
                    ok = false;
                    break;
                }
                covered[member] = true;
                at.* = member;
            }
            if (!ok) {
                self.temporary().free(members);
                usable = false;
                continue;
            }
            if (members.len > 1) any_multi = true;
            slot.* = members;
            continue;
        }
        const member = declared.findMember(arm.name) orelse {
            try failUnknownMember(self, declared, arm.name, arm.name_span);
            usable = false;
            continue;
        };
        // A payload binding list belongs to a union's arms
        // (docs/UNION.md D5); an enum's members carry nothing.
        if (arm.bindings.len != 0) {
            try self.fail(
                "luce.sema.match",
                arm.span,
                "{s} is an enum, and its members carry nothing to bind: write '{s}:'",
                .{ declared.name, arm.name },
            );
            usable = false;
            continue;
        }
        if (covered[member]) {
            try self.fail(
                "luce.sema.match",
                arm.name_span,
                "{s} already has an arm in this match",
                .{arm.name},
            );
            usable = false;
            continue;
        }
        covered[member] = true;
        const one = try self.temporary().alloc(u32, 1);
        one[0] = member;
        slot.* = one;
    }
    if (!usable) return;

    var missing: usize = 0;
    for (covered) |named| {
        if (!named) missing += 1;
    }
    if (matched.else_span) |span| {
        // An else that can never run is the coalesce's own refusal,
        // and it is refused for the reason exhaustiveness exists:
        // an arm that covers nothing today would quietly cover the
        // member somebody adds tomorrow, which is exactly the
        // mistake a checked match is here to make impossible.
        if (missing == 0) {
            try self.fail(
                "luce.sema.match",
                span,
                "every member of {s} already has an arm, so this else can never run; drop it",
                .{declared.name},
            );
            return;
        }
    } else if (missing != 0) {
        try failMissingArms(self, declared, covered, missing, matched.span);
        return;
    }

    // The scrutinee is read once and carried in a slot: a register
    // never crosses a block, and every arm's test is a block.  The
    // slot borrows — the ledger keeps the scrutinee's own park open
    // across the arms, because the match *is* the statement a
    // temporary lives to the end of (S3).
    const held = try recorder.recordLocal(self, null, scrutinee.value_type, false, matched.scrutinee.span());
    // A multi-member arm tests several equalities, and MIR spells the
    // `or` between them as a flag slot the way a value arm does; a
    // match of only single-member arms needs none.  Allocated right
    // after `held` so lower reproduces the slot table in step.
    const flag: ?nodes.LocalId = if (any_multi)
        try recorder.recordLocal(self, null, .boolean, false, matched.span)
    else
        null;

    // Facts an arm proves are the arm's own, and one that assigns
    // over a narrowed name unproves it for everybody after
    // (`lowerWhile` widens the same way, for the same reason).
    const entry = try flow.narrowSave(self);
    defer self.temporary().free(entry);

    // With no else and every member named, the last arm needs no
    // test: it is where a value that matched nothing above must be.
    const fallthrough = matched.else_block == null;
    const tested = if (fallthrough) matched.arms.len - 1 else matched.arms.len;

    const recorded_arms = try self.arena().alloc(nodes.Statement.Match.Arm, matched.arms.len);
    var else_recorded: ?nodes.Block = null;
    for (matched.arms[0..tested], chosen[0..tested], recorded_arms[0..tested]) |arm, members, *recorded_arm| {
        try flow.narrowRestore(self, entry);
        try lowerBlock(self, arm.body);
        recorded_arm.* = .{ .chooses = try memberChoice(self, members), .bindings = &.{}, .body = self.recorded_block.? };
    }
    try flow.narrowRestore(self, entry);
    if (matched.else_block) |otherwise| {
        try lowerBlock(self, otherwise);
        else_recorded = self.recorded_block.?;
    } else {
        const last = matched.arms[matched.arms.len - 1].body;
        try lowerBlock(self, last);
        recorded_arms[matched.arms.len - 1] = .{
            .chooses = try memberChoice(self, chosen[matched.arms.len - 1]),
            .bindings = &.{},
            .body = self.recorded_block.?,
        };
    }

    try flow.narrowRestore(self, entry);
    for (matched.arms) |arm| flow.widenAssignedIn(self, arm.body);
    if (matched.else_block) |otherwise| flow.widenAssignedIn(self, otherwise);

    // The scrutinee's temporary dies here, after the arms that read
    // it through the held slot (S3, docs/UNION.md's "the match *is*
    // the statement").  An arm that leaves early releases it on its
    // own way out, from the floor its `return`/`break` records.
    ledger.flushTemps(self, temps_floor);

    try recorder.recordStatement(self, .{ .match = .{
        .scrutinee = scrutinee.node,
        .held = held,
        .flag = flag,
        .arms = recorded_arms,
        .else_body = else_recorded,
        .span = matched.span,
    } });
}

/// One member is a direct comparison; several are an `or` the flag
/// slot spells.  The slice is duped into the tree's arena because
/// `chosen`'s lives only for the check.
fn memberChoice(self: *FunctionBuilder, members: []const u32) Error!nodes.Statement.Match.Choice {
    if (members.len == 1) return .{ .member = members[0] };
    return .{ .members = try self.arena().dupe(u32, members) };
}

/// `match code:` over a value — the integers, `char`, `str`, and
/// `bool` take literal arms (ENUMS R1's discipline without the
/// names): each arm lists exact literals and, for integers and
/// `char`, inclusive `low .. high` ranges, several per arm behind
/// commas.  The first arm that admits the value wins, which is what
/// makes an overlapping range a style question rather than an error —
/// but the same exact literal twice is a dead arm, and that is
/// refused.  `else` is required unless the arms provably cover
/// everything, which only `bool` can say.
fn lowerValueMatch(
    self: *FunctionBuilder,
    matched: ast.Match,
    scrutinee: Typed,
    temps_floor: usize,
) Error!void {
    const value_type = scrutinee.value_type;
    const ranged = value_type.isInteger() or value_type == .char;
    const type_name = try self.analyzer.typeName(value_type);

    var usable = true;
    var saw_true = false;
    var saw_false = false;

    // Exact literals already claimed, for the dead-arm diagnosis.
    // Integers, chars, and bools compare as numbers; a str compares
    // as its interned constant-pool slot.
    var seen_numbers: std.ArrayList(i128) = .empty;
    defer seen_numbers.deinit(self.temporary());
    var seen_texts: std.ArrayList(u32) = .empty;
    defer seen_texts.deinit(self.temporary());

    const recorded_patterns = try self.arena().alloc(
        []nodes.Statement.Match.Pattern,
        matched.arms.len,
    );
    for (matched.arms, recorded_patterns) |arm, *slot| {
        slot.* = &.{};
        // `limit:` — a bare name parses as a member arm, and over a
        // value it is read as a constant pattern: a folded constant
        // is a literal the compiler can read, and anything else is
        // refused by the same sentences a written pattern earns.
        var name_patterns: [1]ast.ValuePattern = undefined;
        var values = arm.values;
        if (values.len == 0) {
            if (arm.bindings.len != 0) {
                try self.fail(
                    "luce.sema.match",
                    arm.span,
                    "a value arm binds nothing: a literal has no fields",
                    .{},
                );
                usable = false;
                continue;
            }
            const reference = try self.arena().create(ast.Expression);
            reference.* = .{ .name = .{ .text = arm.name, .span = arm.name_span } };
            name_patterns[0] = .{ .low = reference, .high = null, .span = arm.name_span };
            values = name_patterns[0..1];
        }
        const patterns = try self.arena().alloc(nodes.Statement.Match.Pattern, values.len);
        for (values, patterns) |pattern, *recorded| {
            recorded.* = .{ .low = scrutinee.node, .high = null };
            const low = (try lowerPatternLiteral(self, pattern.low, value_type)) orelse {
                usable = false;
                continue;
            };
            recorded.low = low.node;
            if (pattern.high) |top_expression| {
                if (!ranged) {
                    try self.fail(
                        "luce.sema.match",
                        pattern.span,
                        "{s} has no ranges to match: list each value, separated by commas",
                        .{type_name},
                    );
                    usable = false;
                    continue;
                }
                const high = (try lowerPatternLiteral(self, top_expression, value_type)) orelse {
                    usable = false;
                    continue;
                };
                recorded.high = high.node;
                const bottom = patternConstant(self, low.node) orelse unreachable;
                const top = patternConstant(self, high.node) orelse unreachable;
                if (bottom > top) {
                    try self.fail(
                        "luce.sema.match",
                        pattern.span,
                        "this range is empty: its low end is above its high end, and a range is written low .. high",
                        .{},
                    );
                    usable = false;
                    continue;
                }
                continue;
            }
            // An exact literal: claim it, once.
            switch (low.node.*) {
                .const_str => |text| {
                    if (std.mem.indexOfScalar(u32, seen_texts.items, text.constant) != null) {
                        try self.fail(
                            "luce.sema.match",
                            pattern.span,
                            "this value already has an arm in this match",
                            .{},
                        );
                        usable = false;
                        continue;
                    }
                    try seen_texts.append(self.temporary(), text.constant);
                },
                .const_boolean => |literal| {
                    const claimed = if (literal.value) &saw_true else &saw_false;
                    if (claimed.*) {
                        try self.fail(
                            "luce.sema.match",
                            pattern.span,
                            "this value already has an arm in this match",
                            .{},
                        );
                        usable = false;
                        continue;
                    }
                    claimed.* = true;
                },
                else => {
                    const number = patternConstant(self, low.node) orelse unreachable;
                    if (std.mem.indexOfScalar(i128, seen_numbers.items, number) != null) {
                        try self.fail(
                            "luce.sema.match",
                            pattern.span,
                            "this value already has an arm in this match",
                            .{},
                        );
                        usable = false;
                        continue;
                    }
                    try seen_numbers.append(self.temporary(), number);
                },
            }
        }
        slot.* = patterns;
    }
    if (!usable) return;

    // Only `bool` can prove its arms complete; everything else needs
    // the arm for the values nobody named.
    const covered = value_type == .boolean and saw_true and saw_false;
    if (matched.else_span) |span| {
        if (covered) {
            try self.fail(
                "luce.sema.match",
                span,
                "true and false both have arms, so this else can never run; drop it",
                .{},
            );
            return;
        }
    } else if (!covered) {
        try self.fail(
            "luce.sema.match",
            matched.span,
            "a match over {s} needs an else: the arms name some values, and something must catch the rest",
            .{type_name},
        );
        return;
    }

    const held = try recorder.recordLocal(self, null, value_type, false, matched.scrutinee.span());
    const flag = try recorder.recordLocal(self, null, .boolean, false, matched.span);

    const entry = try flow.narrowSave(self);
    defer self.temporary().free(entry);

    const fallthrough = matched.else_block == null;
    const tested = if (fallthrough) matched.arms.len - 1 else matched.arms.len;

    const recorded_arms = try self.arena().alloc(nodes.Statement.Match.Arm, matched.arms.len);
    var else_recorded: ?nodes.Block = null;
    for (matched.arms[0..tested], recorded_patterns[0..tested], recorded_arms[0..tested]) |arm, patterns, *recorded_arm| {
        try flow.narrowRestore(self, entry);
        try lowerBlock(self, arm.body);
        recorded_arm.* = .{
            .chooses = .{ .values = patterns },
            .bindings = &.{},
            .body = self.recorded_block.?,
        };
    }
    try flow.narrowRestore(self, entry);
    if (matched.else_block) |otherwise| {
        try lowerBlock(self, otherwise);
        else_recorded = self.recorded_block.?;
    } else {
        try lowerBlock(self, matched.arms[matched.arms.len - 1].body);
        recorded_arms[matched.arms.len - 1] = .{
            .chooses = .{ .values = recorded_patterns[matched.arms.len - 1] },
            .bindings = &.{},
            .body = self.recorded_block.?,
        };
    }

    try flow.narrowRestore(self, entry);
    for (matched.arms) |arm| flow.widenAssignedIn(self, arm.body);
    if (matched.else_block) |otherwise| flow.widenAssignedIn(self, otherwise);

    ledger.flushTemps(self, temps_floor);

    try recorder.recordStatement(self, .{ .match = .{
        .scrutinee = scrutinee.node,
        .held = held,
        .flag = flag,
        .arms = recorded_arms,
        .else_body = else_recorded,
        .span = matched.span,
    } });
}

/// The integer constant behind a recorded pattern, carried wide: a
/// u64 literal's top half does not fit i64, and a pattern only needs
/// the value for ordering and duplicate checks, both of which i128
/// answers for every width.
fn patternConstant(self: *const FunctionBuilder, node: nodes.NodeRef) ?i128 {
    return switch (node.*) {
        .const_integer => |literal| literal.value,
        .constant_ref => |use| blk: {
            const info = self.analyzer.constant_infos.items[use.constant];
            break :blk if (info.value == .integer) info.value.integer else null;
        },
        .convert => |conversion| patternConstant(self, conversion.operand),
        else => null,
    };
}

/// One pattern literal, landed on the scrutinee's type.  The parser
/// let any expression through so this refusal can say what it found:
/// the pattern must be a literal the compiler can read — a folded
/// constant is one — because a match dispatches on values the program
/// text names, not on values a run computes.
fn lowerPatternLiteral(
    self: *FunctionBuilder,
    expression: *ast.Expression,
    wanted: Type,
) Error!?Typed {
    self.wantPlace(wanted);
    const lowered = (try self.lowerExpression(expression, false)) orelse return null;
    if (!lowered.value_type.eql(wanted)) {
        try self.fail(
            "luce.sema.match",
            expression.span(),
            "this match is over {s}, and this pattern is {s}",
            .{
                try self.analyzer.typeName(wanted),
                try self.analyzer.typeName(lowered.value_type),
            },
        );
        return null;
    }
    const folded = switch (wanted) {
        .str => lowered.node.* == .const_str,
        .boolean => lowered.node.* == .const_boolean,
        else => patternConstant(self, lowered.node) != null,
    };
    if (!folded) {
        try self.fail(
            "luce.sema.match",
            expression.span(),
            "an arm's pattern is a literal the compiler can read, and this value is computed at run time",
            .{},
        );
        return null;
    }
    return lowered;
}

/// `match j:` over a union — ENUMS R1 extended, not forked
/// (docs/UNION.md D5): the same exhaustiveness, `else` and
/// duplicate-arm rules, dispatch on `variant_tag` instead of the
/// value, and an arm may bind its member's payload fields, each by
/// the field's own name, all of them or none.
fn lowerVariantMatch(
    self: *FunctionBuilder,
    matched: ast.Match,
    scrutinee: Typed,
    temps_floor: usize,
) Error!void {
    const variant_index = scrutinee.value_type.variant;
    const declared = self.analyzer.variants.items[variant_index];

    // Which members each arm names, and which members were named:
    // both are needed before anything is lowered, because whether
    // the *last* arm is a comparison or the fallthrough depends on
    // the whole set.  A `left, right:` arm names several members and
    // binds none — a payload binding belongs to a single member.
    const chosen = try self.temporary().alloc([]u32, matched.arms.len);
    defer {
        for (chosen) |list| self.temporary().free(list);
        self.temporary().free(chosen);
    }
    @memset(chosen, &.{});
    const covered = try self.temporary().alloc(bool, declared.members.len);
    defer self.temporary().free(covered);
    @memset(covered, false);
    var usable = true;
    var any_multi = false;
    for (matched.arms, chosen) |arm, *slot| {
        // `left, right:` — several members behind commas, each a bare
        // name with no range, binding nothing.
        if (arm.values.len != 0) {
            const members = try self.temporary().alloc(u32, arm.values.len);
            var ok = true;
            for (arm.values, members) |pattern, *at| {
                if (pattern.high != null or pattern.low.* != .name) {
                    try self.fail(
                        "luce.sema.match",
                        pattern.span,
                        "{s} dispatches by member name; a literal arm belongs to a match over a value",
                        .{declared.name},
                    );
                    ok = false;
                    break;
                }
                const member_index = declared.findMember(pattern.low.name.text) orelse {
                    try failUnknownVariantMember(self, declared, pattern.low.name.text, pattern.low.name.span);
                    ok = false;
                    break;
                };
                if (covered[member_index]) {
                    try self.fail(
                        "luce.sema.match",
                        pattern.span,
                        "{s} already has an arm in this match",
                        .{pattern.low.name.text},
                    );
                    ok = false;
                    break;
                }
                covered[member_index] = true;
                at.* = member_index;
            }
            if (!ok) {
                self.temporary().free(members);
                usable = false;
                continue;
            }
            if (members.len > 1) any_multi = true;
            slot.* = members;
            continue;
        }
        const member_index = declared.findMember(arm.name) orelse {
            try failUnknownVariantMember(self, declared, arm.name, arm.name_span);
            usable = false;
            continue;
        };
        if (!try checkArmBindings(self, declared, member_index, arm)) {
            usable = false;
            continue;
        }
        if (covered[member_index]) {
            try self.fail(
                "luce.sema.match",
                arm.name_span,
                "{s} already has an arm in this match",
                .{arm.name},
            );
            usable = false;
            continue;
        }
        covered[member_index] = true;
        const one = try self.temporary().alloc(u32, 1);
        one[0] = member_index;
        slot.* = one;
    }
    if (!usable) return;

    var missing: usize = 0;
    for (covered) |named| {
        if (!named) missing += 1;
    }
    if (matched.else_span) |span| {
        if (missing == 0) {
            try self.fail(
                "luce.sema.match",
                span,
                "every member of {s} already has an arm, so this else can never run; drop it",
                .{declared.name},
            );
            return;
        }
    } else if (missing != 0) {
        try failMissingVariantArms(self, declared, covered, missing, matched.span);
        return;
    }

    // The scrutinee is read once and carried in a slot: a register
    // never crosses a block, and every arm's test is a block.  The
    // slot borrows — the ledger keeps the scrutinee's own park open
    // across the arms, because the match *is* the statement a
    // temporary lives to the end of (S3), and an arm's payload
    // binding aliases the run that park owns (D10).
    const held = try recorder.recordLocal(self, null, scrutinee.value_type, false, matched.scrutinee.span());
    // A multi-member arm tests several tags, and MIR spells the `or`
    // between them as a flag slot; a match of only single-member arms
    // needs none.  Allocated right after `held` so lower reproduces
    // the slot table in step.
    const flag: ?nodes.LocalId = if (any_multi)
        try recorder.recordLocal(self, null, .boolean, false, matched.span)
    else
        null;

    // Facts an arm proves are the arm's own, and one that assigns
    // over a narrowed name unproves it for everybody after.
    const entry = try flow.narrowSave(self);
    defer self.temporary().free(entry);

    // With no else and every member named, the last arm needs no
    // test: it is where a value that matched nothing above must be.
    const fallthrough = matched.else_block == null;
    const tested = if (fallthrough) matched.arms.len - 1 else matched.arms.len;

    const recorded_arms = try self.arena().alloc(nodes.Statement.Match.Arm, matched.arms.len);
    var arms_recorded = true;
    var else_recorded: ?nodes.Block = null;
    for (matched.arms[0..tested], chosen[0..tested], recorded_arms[0..tested]) |arm, members, *recorded_arm| {
        try flow.narrowRestore(self, entry);
        if (try lowerVariantArmMembers(self, variant_index, members, arm, held)) |lowered_arm| {
            recorded_arm.* = lowered_arm;
        } else arms_recorded = false;
    }
    try flow.narrowRestore(self, entry);
    if (matched.else_block) |otherwise| {
        try lowerBlock(self, otherwise);
        else_recorded = self.recorded_block.?;
    } else {
        const last = matched.arms[matched.arms.len - 1];
        if (try lowerVariantArmMembers(self, variant_index, chosen[matched.arms.len - 1], last, held)) |lowered_arm| {
            recorded_arms[matched.arms.len - 1] = lowered_arm;
        } else arms_recorded = false;
    }

    try flow.narrowRestore(self, entry);
    for (matched.arms) |arm| flow.widenAssignedIn(self, arm.body);
    if (matched.else_block) |otherwise| flow.widenAssignedIn(self, otherwise);

    // The scrutinee's temporary dies here, after the arms that read
    // it through the held slot (S3, docs/UNION.md's "the match *is*
    // the statement").  An arm that leaves early releases it on its
    // own way out, from the floor its `return`/`break` records.
    ledger.flushTemps(self, temps_floor);

    if (arms_recorded) {
        try recorder.recordStatement(self, .{ .match = .{
            .scrutinee = scrutinee.node,
            .held = held,
            .flag = flag,
            .arms = recorded_arms,
            .else_body = else_recorded,
            .span = matched.span,
        } });
    }
}

/// A union arm naming one member or several.  One member keeps the
/// payload-binding path (docs/UNION.md D5); several bind nothing —
/// a payload belongs to a single member — so the body lowers plain
/// and the choice is the member list the flag slot dispatches on.
fn lowerVariantArmMembers(
    self: *FunctionBuilder,
    variant_index: u32,
    members: []const u32,
    arm: ast.MatchArm,
    held: LocalId,
) Error!?nodes.Statement.Match.Arm {
    if (members.len == 1) return lowerVariantArm(self, variant_index, members[0], arm, held);
    try lowerBlock(self, arm.body);
    return .{
        .chooses = .{ .members = try self.arena().dupe(u32, members) },
        .bindings = &.{},
        .body = self.recorded_block.?,
    };
}

/// One arm's binding list against its member's field list
/// (docs/UNION.md D5, amended by the R1 ruling): bindings are
/// **positional** — the n-th name binds the n-th payload field, and
/// the name is the arm's own choice (Swift's shape), which is what
/// lets two nested matches on one member pick different names.  All
/// of them or none: a partial list is refused naming what is
/// missing.  False after reporting.
fn checkArmBindings(
    self: *FunctionBuilder,
    declared: types.VariantType,
    member_index: u32,
    arm: ast.MatchArm,
) Error!bool {
    if (arm.bindings.len == 0) return true;
    const member = declared.members[member_index];
    if (member.fields.len == 0) {
        try self.fail(
            "luce.sema.match",
            arm.span,
            "{s}.{s} carries no payload: write '{s}:'",
            .{ declared.name, member.name, arm.name },
        );
        return false;
    }
    for (arm.bindings, 0..) |binding, at| {
        for (arm.bindings[0..at]) |earlier| {
            if (!std.mem.eql(u8, earlier.text, binding.text)) continue;
            try self.fail("luce.sema.match", binding.span, "{s} bound twice", .{binding.text});
            return false;
        }
    }
    if (arm.bindings.len != member.fields.len) {
        try self.fail(
            "luce.sema.match",
            arm.span,
            "{s}.{s} carries {d} field(s) and this arm names {d}; an arm binds every field in order, or write '{s}:' to bind none",
            .{ declared.name, member.name, member.fields.len, arm.bindings.len, arm.name },
        );
        return false;
    }
    return true;
}

/// One arm's body, with its payload bindings in a scope of their
/// own — like `catch NAME:`'s (docs/UNION.md D11).  Each binding
/// is an alias of what the scrutinee owns (D10): reading through
/// it is free, keeping it needs `copy`, and a value payload is an
/// ordinary copy taken by the store.
///
/// Answers the recorded arm for the match node — the member, the
/// bindings with their payload reads, the body — or null when a
/// binding could not be declared, which gaps the whole match.
fn lowerVariantArm(
    self: *FunctionBuilder,
    variant_index: u32,
    member_index: u32,
    arm: ast.MatchArm,
    held: LocalId,
) Error!?nodes.Statement.Match.Arm {
    if (arm.bindings.len == 0) {
        try lowerBlock(self, arm.body);
        return .{ .chooses = .{ .member = member_index }, .bindings = &.{}, .body = self.recorded_block.? };
    }
    const member = self.analyzer.variants.items[variant_index].members[member_index];
    const recorded_bindings = try self.arena().alloc(nodes.Statement.Match.Binding, member.fields.len);
    var bindings_recorded = true;
    try self.pushScope();
    for (member.fields, 0..) |field, field_index| {
        // Positional (R1): the n-th written name takes the n-th
        // payload field, whatever either is called.
        const written = arm.bindings[field_index];
        const declared_at = written.span;
        // The scrutinee read is a local reload of the held slot,
        // and its node says so; the payload read hangs off it.
        const scrutinee = try recorder.recordNode(self, .{ .local_get = .{
            .local = held,
            .result = recorder.localType(self, held),
            .span = declared_at,
        } });
        // A payload read is a view into the scrutinee's run
        // (docs/UNION.md D10), so the store below copies it.
        const value: Typed = .{
            .node = try recorder.recordNode(self, .{ .variant_payload = .{
                .target = scrutinee,
                .variant = variant_index,
                .member = member_index,
                .field = @intCast(field_index),
                .result = field.field_type,
                .span = declared_at,
            } }),
            .value_type = field.field_type,
        };
        const local = (try self.declareLocal(
            written.text,
            field.field_type,
            false,
            declared_at,
        )) orelse {
            bindings_recorded = false;
            continue;
        };
        recorded_bindings[field_index] = .{ .local = local, .payload = value.node };
        ledger.storeOwned(self, local, value);
    }
    try lowerBlock(self, arm.body);
    const body = self.recorded_block.?;
    self.popScope();
    if (!bindings_recorded) return null;
    return .{ .chooses = .{ .member = member_index }, .bindings = recorded_bindings, .body = body };
}

/// The members a union match with no `else` left out, named — all
/// of them, in declaration order (`failMissingArms`' sentence, one
/// table over).
fn failMissingVariantArms(
    self: *FunctionBuilder,
    declared: types.VariantType,
    covered: []const bool,
    missing: usize,
    span: Span,
) Error!void {
    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(self.temporary());
    var written_so_far: usize = 0;
    for (covered, 0..) |named, index| {
        if (named) continue;
        if (written_so_far != 0) {
            if (missing > 2) try written.appendSlice(self.temporary(), ",");
            try written.appendSlice(self.temporary(), " ");
            if (written_so_far + 1 == missing) try written.appendSlice(self.temporary(), "and ");
        }
        try written.appendSlice(self.temporary(), declared.members[index].name);
        written_so_far += 1;
    }
    try self.fail(
        "luce.sema.match",
        span,
        "this match has no arm for {s} {s} of {s}; write {s}, or an else for everything the arms above do not name",
        .{
            if (missing == 1) "member" else "members",
            written.items,
            declared.name,
            if (missing == 1) "one" else "them",
        },
    );
}

/// A match arm, or a `Method.x`, naming something the enum has not.
pub fn failUnknownMember(
    self: *FunctionBuilder,
    declared: types.EnumType,
    written: []const u8,
    span: Span,
) Error!void {
    var suggestion = helpers.Suggestion.init(written);
    for (declared.members) |member| suggestion.offer(member.name);
    try failNoSuchMember(self, declared.name, suggestion.best(), written, span);
}

/// The union twin: a match arm, or a `Shape.x`, naming something
/// the union has not.
pub fn failUnknownVariantMember(
    self: *FunctionBuilder,
    declared: types.VariantType,
    written: []const u8,
    span: Span,
) Error!void {
    var suggestion = helpers.Suggestion.init(written);
    for (declared.members) |member| suggestion.offer(member.name);
    try failNoSuchMember(self, declared.name, suggestion.best(), written, span);
}

/// The one sentence both kinds say about a name their members do
/// not spell.
fn failNoSuchMember(
    self: *FunctionBuilder,
    declared_name: []const u8,
    closest: ?[]const u8,
    written: []const u8,
    span: Span,
) Error!void {
    if (closest) |offered| {
        try self.fail("luce.sema.match", span, "{s} is not a member of {s}; did you mean {s}?", .{
            written,
            declared_name,
            offered,
        });
        return;
    }
    try self.fail("luce.sema.match", span, "{s} is not a member of {s}", .{ written, declared_name });
}

/// The members a match with no `else` left out, named — all of
/// them, in declaration order, because a reader who has to compile
/// again to learn the next one is doing the compiler's work
/// (`context.writeMissingFields` is the same sentence for a struct).
fn failMissingArms(
    self: *FunctionBuilder,
    declared: types.EnumType,
    covered: []const bool,
    missing: usize,
    span: Span,
) Error!void {
    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(self.temporary());
    var written_so_far: usize = 0;
    for (covered, 0..) |named, index| {
        if (named) continue;
        if (written_so_far != 0) {
            if (missing > 2) try written.appendSlice(self.temporary(), ",");
            try written.appendSlice(self.temporary(), " ");
            if (written_so_far + 1 == missing) try written.appendSlice(self.temporary(), "and ");
        }
        try written.appendSlice(self.temporary(), declared.members[index].name);
        written_so_far += 1;
    }
    try self.fail(
        "luce.sema.match",
        span,
        "this match has no arm for {s} {s} of {s}; write {s}, or an else for everything the arms above do not name",
        .{
            if (missing == 1) "member" else "members",
            written.items,
            declared.name,
            if (missing == 1) "one" else "them",
        },
    );
}

/// `name_span` is the name alone and `span` the whole statement:
/// a complaint about the word points at the word, and one about
/// what the statement says points at the statement.
fn lowerBinding(
    self: *FunctionBuilder,
    name: []const u8,
    name_span: Span,
    annotation: ?ast.TypeName,
    value_expression: *ast.Expression,
    mutable: bool,
    weak: bool,
    span: Span,
) Error!void {
    const previous_permission = self.allow_deinitializer_self;
    defer self.allow_deinitializer_self = previous_permission;
    if (self.lifecycle == .deinitializer and weak and builder.isBareSelf(value_expression)) {
        self.allow_deinitializer_self = true;
    }
    // A binding whose initializer failed still declares a name the
    // reader meant; remembering it keeps one mistake from
    // producing an "unknown name" per later use.
    var value: Typed = undefined;
    // The annotation said `T?` and the initializer handed over a
    // plain `T`, so the binding starts out present.
    var wrapped_optional = false;
    if (weak and annotation == null) {
        try self.fail(
            "luce.sema.weak.target",
            name_span,
            "weak variable {s} needs an explicit optional ARC type, for example 'weak var {s}: list[i64]? = value'",
            .{ name, name },
        );
        return refusals.forgetName(self, name);
    }
    if (annotation) |written| {
        const expected = (try resolve.resolveType(self.analyzer, self.module, written)) orelse
            return refusals.forgetName(self, name);
        if (weak and !shapes.weakTarget(self.analyzer, expected)) {
            try self.fail(
                "luce.sema.weak.target",
                written.span,
                "weak variable {s} must be an optional list, map, array, builder, or class reference, not {s}",
                .{ name, try self.analyzer.typeName(expected) },
            );
            return refusals.forgetName(self, name);
        }
        if (value_expression.* == .none_literal) {
            value = ((try self.lowerTyped(value_expression, expected, span, name)) orelse
                return refusals.forgetName(self, name)).value;
        } else {
            self.wantPlace(expected);
            const initializer = (try self.lowerExpression(value_expression, false)) orelse
                return refusals.forgetName(self, name);
            value = (try self.fit(initializer, expected)) orelse {
                // Numeric representations have explicit constructors;
                // unrelated types do not. The suffix distinguishes those
                // two errors without implying either conversion is hidden.
                const narrowing = try refusals.narrowingAdvice(self, expected, initializer.value_type);
                try self.fail(
                    "luce.sema.type",
                    span,
                    "{s} declared {s} but initialized with {s}{s}{s}",
                    .{
                        name,
                        try self.analyzer.typeName(expected),
                        try self.analyzer.typeName(initializer.value_type),
                        if (narrowing.len != 0) narrowing else ", and there is no conversion between them",
                        try refusals.absenceAdvice(self, initializer.value_type, value_expression),
                    },
                );
                return refusals.forgetName(self, name);
            };
            wrapped_optional = !initializer.value_type.eql(expected);
        }
    } else {
        value = (try self.lowerExpression(value_expression, false)) orelse
            return refusals.forgetName(self, name);
    }
    const local = (if (weak)
        try self.declareWeakLocal(name, value.value_type, name_span)
    else
        try self.declareLocal(name, value.value_type, mutable, name_span)) orelse
        return refusals.forgetName(self, name);
    const store = ledger.storeOwnedKind(self, local, value);
    // `let x: i64? = 5` is optional in its type and present in
    // fact, and the reader should not have to test what they just
    // wrote.
    if (wrapped_optional and !weak) try flow.narrow(self, local);
    try recorder.recordStatement(self, .{ .declare = .{
        .local = local,
        .value = value.node,
        .store = store,
        .span = span,
    } });
    if (mutable) try closures.captureMutableBinding(self, name, local, value.value_type, weak, name_span);
}

const ReceivedShape = struct { value: Typed, layout: StructLayout };

/// Lower one expression where a destructuring statement can
/// receive a return shape, and check that its arity is the number
/// of names written on the left.  Both a declaring bind and an
/// existing-name assignment use this one call boundary.
fn lowerReceivedShape(
    self: *FunctionBuilder,
    expression: *ast.Expression,
    span: Span,
    count: usize,
) Error!?ReceivedShape {
    self.shape_position = .receive;
    const value = (try self.lowerExpression(expression, false)) orelse return null;
    const shape = signatures.returnShapeOf(self.analyzer, value.value_type) orelse {
        // One value, two names.  Naming the call is what makes the
        // sentence actionable, and the call is right there.
        try self.fail(
            "luce.sema.shape",
            span,
            "{s} answers 1 value, got {d} names",
            .{ try calledName(self, expression), count },
        );
        return null;
    };
    if (shape.fields.len != count) {
        try self.fail(
            "luce.sema.shape",
            span,
            "{s} answers {d} values, got {d} name{s}",
            .{
                try calledName(self, expression),
                shape.fields.len,
                count,
                helpers.plural(count),
            },
        );
        return null;
    }
    return .{ .value = value, .layout = shape };
}

/// `let low, high = minmax(xs)` — a call answering a return shape
/// declares one name for each value (docs/RETURNS.md).
///
/// Under the lowering the shape is one struct, so this is one
/// `call` and one `struct_get` per name: S1 per name, as it says.
fn lowerDestructure(self: *FunctionBuilder, bind: ast.Destructure) Error!void {
    const received = (try lowerReceivedShape(self, bind.value, bind.span, bind.names.len)) orelse {
        for (bind.names) |name| try refusals.forgetName(self, name.text);
        return;
    };

    // Each value moves independently to its own binding, and each
    // binding owns what it received and is freed by its scope
    // (S16 per value, S1 per name, S45).  The struct the values
    // rode in is a statement temporary and dies with the
    // statement; it owns nothing once the fields are out.
    const locals = try self.arena().alloc(LocalId, bind.names.len);
    const stores = try self.arena().alloc(nodes.StoreKind, bind.names.len);
    var complete = true;
    for (bind.names, received.layout.fields, 0..) |name, field, position| {
        const local = (try self.declareLocal(
            name.text,
            field.field_type,
            bind.mutable,
            name.span,
        )) orelse {
            complete = false;
            continue;
        };
        // A field read is a view into the shape's run, so an
        // owning slot's store copies it out (docs/STRINGS.md).
        locals[position] = local;
        stores[position] = if (recorder.localOwnsStorage(self, local) and
            shapes.ownsStorage(self.analyzer, field.field_type)) .copy else .plain;
    }
    if (complete) {
        try recorder.recordStatement(self, .{ .destructure = .{
            .locals = locals,
            .value = received.value.node,
            .stores = stores,
            .span = bind.span,
        } });
        if (bind.mutable) {
            for (bind.names, locals, received.layout.fields) |name, local, field| {
                try closures.captureMutableBinding(self, name.text, local, field.field_type, false, name.span);
            }
        }
    }
}

const ExistingTarget = struct {
    name: ast.Name,
    local: LocalId,
    value_type: Type,
    owns_storage: bool,
    capture_cell: ?context.CaptureCell,
};

const PreparedTarget = struct {
    target: ExistingTarget,
    present: bool,
};

/// Whether `actual` reaches `expected` through exact matching or optional
/// wrapping — the compatibility half of `fit`, for shaped receives whose
/// per-value fits are re-derived by lower.
fn fitsInto(actual: Type, expected: Type) bool {
    if (actual.eql(expected)) return true;
    const payload = expected.held() orelse return false;
    return fitsInto(actual, payload);
}

/// Validate one target of an existing-name destructuring
/// assignment before its call runs.  A returned object is fresh
/// (S16/S45), so only an owning var can receive one.
fn existingTarget(self: *FunctionBuilder, name: ast.Name) Error!?ExistingTarget {
    const found = self.findLocal(name.text) orelse {
        const qualified = try naming.qualify(self.analyzer, self.prefix, name.text);
        if (self.analyzer.constant_names.contains(qualified)) {
            try self.fail("luce.sema.const", name.span, "{s} is a file-scope constant and cannot be assigned", .{name.text});
        } else {
            try refusals.failUnknownName(self, name.text, name.span);
        }
        return null;
    };
    const info = found.info;
    if (!info.mutable) {
        try self.fail("luce.sema.let", name.span, "{s} is let-bound; use var for reassignment", .{name.text});
        return null;
    }
    if (info.iterating) {
        try self.fail(
            "luce.sema.own",
            name.span,
            "{s} is being iterated; reassigning it would invalidate the collection under the loop",
            .{name.text},
        );
        return null;
    }
    return .{
        .name = name,
        .local = info.local,
        .value_type = recorder.localType(self, info.local),
        .owns_storage = if (info.capture_cell) |cell|
            !cell.weak and shapes.ownsStorage(self.analyzer, recorder.localType(self, info.local))
        else
            recorder.localOwnsStorage(self, info.local),
        .capture_cell = info.capture_cell,
    };
}

/// `low, high = minmax(xs)` — replace two or more existing vars
/// from one return shape.  Every target is checked first, then
/// every result is extracted, fitted, and made safe to store
/// before any old value is released.  That is the parallel/swap
/// semantics and the all-or-none replacement-store boundary a
/// failed call needs.  Ordinary side effects of evaluating the
/// right side have already happened when that call fails.
fn lowerAssignMany(self: *FunctionBuilder, assigned: ast.AssignMany) Error!void {
    const targets = try self.temporary().alloc(ExistingTarget, assigned.names.len);
    defer self.temporary().free(targets);
    for (assigned.names, 0..) |name, index| {
        for (assigned.names[0..index]) |earlier| {
            if (!std.mem.eql(u8, name.text, earlier.text)) continue;
            try self.fail(
                "luce.sema.duplicate",
                name.span,
                "{s} is assigned twice in this statement",
                .{name.text},
            );
            return;
        }
        targets[index] = (try existingTarget(self, name)) orelse return;
    }

    const received = (try lowerReceivedShape(self, assigned.value, assigned.span, assigned.names.len)) orelse return;

    const prepared = try self.temporary().alloc(PreparedTarget, targets.len);
    defer self.temporary().free(prepared);
    const stores = try self.arena().alloc(nodes.StoreKind, targets.len);
    for (targets, received.layout.fields, 0..) |target, field, position| {
        // A field read is a view into the shape's run. It either matches
        // the target exactly or injects `T` into `T?`; lowering derives
        // the same decision from this pair of types.
        if (!fitsInto(field.field_type, target.value_type)) {
            try self.fail(
                "luce.sema.type",
                target.name.span,
                "{s} is {s}, but value {d} from {s} is {s}",
                .{
                    target.name.text,
                    try self.analyzer.typeName(target.value_type),
                    position + 1,
                    try calledName(self, assigned.value),
                    try self.analyzer.typeName(field.field_type),
                },
            );
            return;
        }
        // The replacement store copies a view into an owning slot
        // and stores everything else plain (`ownedForStoreKind`
        // over a view or a wrapped view: never a take).
        stores[position] = if (target.owns_storage and
            shapes.ownsStorage(self.analyzer, target.value_type)) .copy else .plain;
        prepared[position] = .{
            .target = target,
            .present = target.value_type == .optional and field.field_type != .optional,
        };
    }

    for (prepared) |item| {
        if (item.target.value_type == .optional) {
            if (item.present) try flow.narrow(self, item.target.local) else flow.widen(self, item.target.local);
        }
    }
    const target_locals = try self.arena().alloc(LocalId, targets.len);
    const cells = try self.arena().alloc(?nodes.Place.Field, targets.len);
    for (targets, target_locals, cells) |target, *slot, *cell_slot| {
        slot.* = target.local;
        cell_slot.* = if (target.capture_cell) |cell| .{
            .base = cell.local,
            .layout = cell.layout,
            .field = 0,
        } else null;
    }
    try recorder.recordStatement(self, .{ .assign_many = .{
        .targets = target_locals,
        .cells = cells,
        .value = received.value.node,
        .stores = stores,
        .span = assigned.span,
    } });
}

/// The name a reader would recognise the call by, for a message
/// about its arity.
fn calledName(self: *FunctionBuilder, expression: *const ast.Expression) Error![]const u8 {
    return switch (expression.*) {
        .call => |call| call.callee,
        .value_call => |written| calledName(self, written.callee),
        .method => |method| method.name,
        .try_call => |attempt| calledName(self, attempt.operand),
        .spawn => |worker| calledName(self, worker.call),
        else => "this",
    };
}

/// var name: Type — a late declaration (MEMORY.md): the
/// slot starts at the type's zero value; the zero of an object
/// type is the null object, which traps on use until assigned.
fn lowerLateDeclaration(
    self: *FunctionBuilder,
    name: []const u8,
    name_span: Span,
    written: ast.TypeName,
    weak: bool,
    span: Span,
) Error!void {
    const declared = (try resolve.resolveType(self.analyzer, self.module, written)) orelse
        return refusals.forgetName(self, name);
    if (weak and !shapes.weakTarget(self.analyzer, declared)) {
        try self.fail(
            "luce.sema.weak.target",
            written.span,
            "weak variable {s} must be an optional list, map, array, builder, or class reference, not {s}",
            .{ name, try self.analyzer.typeName(declared) },
        );
        return refusals.forgetName(self, name);
    }
    // A function value has no zero: every value of the type names a
    // function, and there is no function to name here.  A slot that
    // starts empty is exactly what `(func(...) -> R)?` is for
    // (docs/BINDING.md D7), so the sentence names both ways out — say
    // which function it is now, or declare the slot as one that may
    // hold none.
    if (declared == .function) {
        try self.fail(
            "luce.sema.type",
            written.span,
            "a function value has no zero: write {s} = the function it names, or var {s}: ({s})? for a slot that starts empty",
            .{ name, name, try self.analyzer.typeName(declared) },
        );
        return refusals.forgetName(self, name);
    }
    if (declared == .strukt and self.analyzer.interfaceForLayout(declared.strukt) != null) {
        try self.fail(
            "luce.sema.interface",
            written.span,
            "an interface value has no default implementation: initialize {s} with a conforming struct",
            .{name},
        );
        return refusals.forgetName(self, name);
    }
    // The declaration establishes the binding and its scope; the
    // scope owns whatever a later assignment fills in (S36, S40).
    const local = (if (weak)
        try self.declareWeakLocal(name, declared, name_span)
    else
        try self.declareLocal(name, declared, true, name_span)) orelse
        return refusals.forgetName(self, name);
    // The zero fill's store decision, from the type alone: a
    // struct or union zero is a fresh built run the slot adopts,
    // an owned-storage scalar zero copies, and everything else is
    // plain (`ownedForStoreKind` over `zeroProvenance`).
    const store: nodes.StoreKind = if (!shapes.ownsStorage(self.analyzer, declared))
        .plain
    else switch (declared) {
        .strukt, .variant => .take,
        else => .copy,
    };
    // A null value is the recorded form of the zero fill (S40):
    // lower re-derives the zero from the slot's type.
    try recorder.recordStatement(self, .{ .declare = .{
        .local = local,
        .value = null,
        .store = store,
        .span = span,
    } });
    try closures.captureMutableBinding(self, name, local, declared, weak, name_span);
}

fn lowerCondition(self: *FunctionBuilder, expression: *ast.Expression) Error!?Typed {
    const condition = (try self.lowerExpression(expression, false)) orelse return null;
    if (condition.value_type != .boolean) {
        try self.fail("luce.sema.type", expression.span(), "condition must be bool, not {s}{s}", .{
            try self.analyzer.typeName(condition.value_type),
            try refusals.absenceAdvice(self, condition.value_type, expression),
        });
        return null;
    }
    return condition;
}

// Control flow: if, while, for, return ------------------------------------

fn lowerConditional(self: *FunctionBuilder, conditional: ast.Conditional) Error!void {
    const temps_floor = self.temps.items.len;
    const condition = (try lowerCondition(self, conditional.condition)) orelse return;
    // Condition temporaries die before the branch: the condition
    // value is a bool, so nothing still needs them.
    ledger.flushTemps(self, temps_floor);

    // The arms run under what the condition decided, and what
    // survives the join is what both of them still agree on.  An
    // arm that always leaves — `if x == none: return` — contributes
    // nothing to the join, which is what makes an early-return
    // guard narrow the rest of the block below it.
    const entry = try flow.narrowSave(self);
    defer self.temporary().free(entry);

    try flow.applyFacts(self, conditional.condition, true, flow.fact_search_depth);
    try lowerBlock(self, conditional.then_block);
    const then_recorded = self.recorded_block.?;
    const after_then = try flow.narrowSave(self);
    defer self.temporary().free(after_then);

    try flow.narrowRestore(self, entry);
    try flow.applyFacts(self, conditional.condition, false, flow.fact_search_depth);
    if (conditional.else_block) |else_block| {
        try lowerBlock(self, else_block);
    }
    const else_recorded: ?nodes.Block = if (conditional.else_block != null) self.recorded_block.? else null;
    try recorder.recordStatement(self, .{ .if_else = .{
        .condition = condition.node,
        .then_body = then_recorded,
        .else_body = else_recorded,
        .span = conditional.span,
    } });

    const then_leaves = helpers.alwaysExits(conditional.then_block);
    const else_leaves = if (conditional.else_block) |else_block|
        helpers.alwaysExits(else_block)
    else
        false;
    if (then_leaves and else_leaves) return; // nothing reaches here
    if (then_leaves) return; // the else arm's state is already current
    if (else_leaves) {
        try flow.narrowRestore(self, after_then);
        return;
    }
    flow.narrowIntersect(self, after_then);
}

fn lowerWhile(self: *FunctionBuilder, loop: ast.While) Error!void {
    // The body runs before the back edge re-enters the header, so
    // anything it assigns may be absent again on the next pass.
    try flow.prepareLoopFacts(self, loop.body);
    const entry = try flow.narrowSave(self);
    defer self.temporary().free(entry);
    // The frame is pushed before the condition lowers: the header
    // re-runs every iteration, so the S30 give/free guard must see
    // the loop there too.
    try self.loops.append(self.temporary(), .{
        .scope_depth = self.scopes.items.len,
        .temps_depth = self.temps.items.len,
    });
    const temps_floor = self.temps.items.len;
    const condition = (try lowerCondition(self, loop.condition)) orelse {
        _ = self.loops.pop();
        return;
    };
    // The header re-runs every iteration: its temporaries must die
    // in it, not after the loop.
    ledger.flushTemps(self, temps_floor);

    try flow.applyFacts(self, loop.condition, true, flow.fact_search_depth);
    try lowerBlock(self, loop.body);
    _ = self.loops.pop();
    // After the loop nothing the body proved still holds: it may
    // have run zero times, and `break` leaves from anywhere.
    try flow.narrowRestore(self, entry);
    try recorder.recordStatement(self, .{ .while_loop = .{
        .condition = condition.node,
        .body = self.recorded_block.?,
        .span = loop.span,
    } });
}

fn lowerForRange(self: *FunctionBuilder, loop: ast.ForRange) Error!void {
    try flow.prepareLoopFacts(self, loop.body);
    const entry = try flow.narrowSave(self);
    defer self.temporary().free(entry);
    const temps_floor = self.temps.items.len;
    const bounds_run = (try self.lowerOperandsIntoTracking(&.{ loop.start, loop.end }, .nothing)) orelse return;
    const bounds = bounds_run.values;
    if (!bounds[0].value_type.eql(.i64) or !bounds[1].value_type.eql(.i64)) {
        try self.fail("luce.sema.type", loop.span, "range bounds must be i64", .{});
        return;
    }
    const start = bounds[0];
    const end = bounds[1];
    // Bound temporaries die before the loop starts.
    ledger.flushTemps(self, temps_floor);

    try self.pushScope();
    defer self.popScope();
    const index_local = (try self.declareLocal(loop.name, .i64, false, loop.span)) orelse return;
    // The loop's hidden limit slot, mirrored into the tree's
    // locals table in creation order (lower's counted loop makes
    // it right after the counter's row).
    _ = try recorder.recordLocal(self, null, .i64, false, loop.span);

    try self.loops.append(self.temporary(), .{
        .scope_depth = self.scopes.items.len,
        .temps_depth = self.temps.items.len,
    });
    try lowerBlock(self, loop.body);
    _ = self.loops.pop();
    try flow.narrowRestore(self, entry);
    try recorder.recordStatement(self, .{ .for_range = .{
        .counter = index_local,
        .start = start.node,
        .stop = end.node,
        .body = self.recorded_block.?,
        .span = loop.span,
    } });
}

/// for x in xs: — the element (or map key) binds immutably each
/// iteration, and a named iterable is locked against reassignment
/// while the loop runs.  What that costs in blocks and hidden
/// locals is `lower.replayForIn`'s.
fn lowerForEach(self: *FunctionBuilder, loop: ast.ForEach) Error!void {
    try flow.prepareLoopFacts(self, loop.body);
    const entry = try flow.narrowSave(self);
    defer self.temporary().free(entry);
    const iterable = (try self.lowerExpression(loop.iterable, false)) orelse return;
    const descriptor = self.analyzer.heapOf(iterable.value_type);
    const scalar_element: ?Type = switch (iterable.value_type) {
        .str => .char,
        .bytes => .u8,
        else => null,
    };
    if (descriptor == null and scalar_element == null) {
        try self.fail("luce.sema.loop", loop.span, "for iterates str, bytes, a list, a rank-1 array, or a map, not {s}{s}", .{
            try self.analyzer.typeName(iterable.value_type),
            try refusals.absenceAdvice(self, iterable.value_type, loop.iterable),
        });
        return;
    }
    // Each collection has a "position" (a map's key, or a
    // list/array's i64 index) and a "payload" (a map's value, or
    // the element).  `for x in c:` binds the payload for
    // sequences and the key for maps (Python's habit); `for a, b
    // in c:` binds position then payload.
    var position_type: Type = .i64;
    const payload_type: Type = scalar_element orelse switch (descriptor.?) {
        .class => {
            try self.fail("luce.sema.loop", loop.span, "a class is not iterable", .{});
            return;
        },
        .channel => {
            try self.fail("luce.sema.loop", loop.span, "a channel is not iterable; loop on receive() until it answers the closed error", .{});
            return;
        },
        .list => |element| element,
        .array => |shape| blk: {
            if (shape.rank != 1) {
                try self.fail("luce.sema.loop", loop.span, "for iterates rank-1 arrays; index higher ranks explicitly", .{});
                return;
            }
            break :blk shape.element;
        },
        .map => |pair| blk: {
            position_type = pair.key;
            break :blk pair.value;
        },
        .builder => {
            try self.fail("luce.sema.loop", loop.span, "builder is not iterable", .{});
            return;
        },
        .handle => {
            try self.fail("luce.sema.loop", loop.span, "handle is not iterable; read it through the class that owns it", .{});
            return;
        },
        .task => {
            try self.fail("luce.sema.loop", loop.span, "task is not iterable; t.wait() answers what the worker did", .{});
            return;
        },
    };

    try self.pushScope();
    defer self.popScope();
    // The iteration's two hidden slots: the collection, then the
    // position, in creation order (lower's `replayForIn` takes the
    // same rows at the same point).
    _ = try recorder.recordLocal(self, null, iterable.value_type, false, loop.span);
    _ = try recorder.recordLocal(self, null, .i64, false, loop.span);

    // Which type each declared name binds at.  Single name:
    // payload for sequences, key for maps.  Two names: first =
    // position, second = payload.
    const two_names = loop.value_name != null;
    const map_like = descriptor != null and descriptor.? == .map;
    const first_type: Type = if (two_names or map_like) position_type else payload_type;
    // A loop name holds a *view* of the element, and the body can
    // invalidate it: an element overwrite frees the old element
    // (S22), and unlike an object — whose handle would go stale
    // and trap — a string has no handle to check
    // (docs/STRINGS.md).  So a body that could free something a
    // container holds gives the name a copy of its own, released
    // at the top of the next iteration and at the end of the loop;
    // a body that provably cannot keeps the borrow, which is what
    // makes `for piece in pieces:` cost nothing.
    const keeps_view = !effects.blockMayMutateContainers(loop.body);
    const storage_class: StorageClass = if (keeps_view) .borrows else .owns;
    const name_local = (try self.declareLocalAs(
        loop.name,
        first_type,
        false,
        storage_class,
        loop.span,
    )) orelse return;
    const value_local: ?LocalId = if (two_names)
        (try self.declareLocalAs(
            loop.value_name.?,
            payload_type,
            false,
            storage_class,
            loop.span,
        )) orelse return
    else
        null;
    // The per-iteration name binds — a getter view or the raw
    // index, plain-stored into a borrowing slot or released and
    // copied into an owning one — are lower's, re-derived from
    // the sequence's shape and the recorded name rows.
    try self.loops.append(self.temporary(), .{
        .scope_depth = self.scopes.items.len,
        .temps_depth = self.temps.items.len,
    });
    // A named iterable is locked against reassignment for the
    // duration of the loop (restored below for outer loops).
    var iterated: ?[]const u8 = null;
    var was_iterating = false;
    if (loop.iterable.* == .name) {
        if (self.findLocal(loop.iterable.name.text)) |iterable_binding| {
            iterated = loop.iterable.name.text;
            was_iterating = iterable_binding.info.iterating;
            iterable_binding.info.iterating = true;
        }
    }
    try lowerBlock(self, loop.body);
    if (iterated) |name| {
        if (self.findLocal(name)) |iterable_binding| {
            iterable_binding.info.iterating = was_iterating;
        }
    }
    _ = self.loops.pop();
    const body_recorded = self.recorded_block.?;
    try flow.narrowRestore(self, entry);
    // The `owns_storage` column of the recorded name rows carries
    // the keeps-view decision, so the statement records the names
    // and the sequence and lower re-derives the whole iteration
    // machinery, the loop-scope releases included.
    try recorder.recordStatement(self, .{ .for_in = .{
        .sequence = iterable.node,
        .first = name_local,
        .second = value_local,
        .body = body_recorded,
        .span = loop.span,
    } });
}

fn lowerReturn(self: *FunctionBuilder, returned: ast.Return) Error!void {
    if (self.lifecycle == .initializer) {
        // The lifecycle validator owns the diagnostic for a value-bearing
        // return. A bare return materializes the class whole here.
        if (returned.values.len != 0) return;
        return initializers.lowerReturn(self, returned.span);
    }
    if (returned.values.len >= 2) return lowerReturnShape(self, returned);
    if (returned.values.len == 1) {
        const expression = returned.values[0];
        if (self.return_type == .none) {
            // Still lower it: an expression with a mistake in it
            // deserves its own message before this one.
            _ = try self.lowerExpression(expression, false);
            try self.fail("luce.sema.return", returned.span, "this function returns nothing", .{});
            return;
        }
        if (expression.* == .none_literal) {
            const absent = (try self.lowerTyped(
                expression,
                self.return_type,
                returned.span,
                "this function's result",
            )) orelse return;
            // `return none` hands the absence over whole — no
            // store decision is made, so the recorded kind is
            // `.plain`.
            const values = try self.arena().alloc(nodes.NodeRef, 1);
            values[0] = absent.value.node;
            const stores = try self.arena().alloc(nodes.StoreKind, 1);
            stores[0] = .plain;
            try recorder.recordStatement(self, .{ .return_ = .{
                .values = values,
                .stores = stores,
                .span = returned.span,
            } });
            return;
        }
        if (self.results.len >= 2) {
            self.shape_position = .returning;
            _ = try self.lowerExpression(expression, false);
            try self.fail("luce.sema.return", returned.span, "{s} answers {d} values, got 1", .{
                self.name, self.results.len,
            });
            return;
        }
        self.wantPlace(self.return_type);
        const lowered = (try self.lowerExpression(expression, false)) orelse return;
        const value = (try self.fit(lowered, self.return_type)) orelse {
            try self.fail("luce.sema.type", returned.span, "returning {s} from a function returning {s}{s}", .{
                try self.analyzer.typeName(lowered.value_type),
                try self.analyzer.typeName(self.return_type),
                try refusals.mismatchAdvice(self, self.return_type, lowered.value_type, expression),
            });
            return;
        };

        // A string-returning function may hand back a view of a
        // parameter (`strings.trim` returns `s[first:last]`) or of a
        // local this frame is about to release, and Luce has no
        // annotation that tells them apart — so the return channel
        // copies, except where the value is provably this statement's
        // own; the export of whatever text rides out is lower's, from
        // `carriesText` (docs/STRINGS.md).
        const handed = ledger.ownedForStoreKind(self, value);
        const values = try self.arena().alloc(nodes.NodeRef, 1);
        values[0] = value.node;
        const stores = try self.arena().alloc(nodes.StoreKind, 1);
        stores[0] = handed;
        try recorder.recordStatement(self, .{ .return_ = .{
            .values = values,
            .stores = stores,
            .span = returned.span,
        } });
        return;
    }
    if (self.return_type != .none) {
        try self.fail("luce.sema.return", returned.span, "return needs a value of type {s}", .{
            try self.analyzer.typeName(self.return_type),
        });
        return;
    }
    try recorder.recordStatement(self, .{ .return_ = .{
        .values = &.{},
        .stores = &.{},
        .span = returned.span,
    } });
}

/// `return a, b`: check each value fits its result slot, decide each
/// slot's value-storage store kind, and record the shaped return.
fn lowerReturnShape(self: *FunctionBuilder, returned: ast.Return) Error!void {
    if (self.results.len < 2) {
        for (returned.values) |expression| _ = try self.lowerExpression(expression, false);
        if (self.results.len == 0) {
            try self.fail("luce.sema.return", returned.span, "this function returns nothing", .{});
            return;
        }
        try self.fail("luce.sema.return", returned.span, "{s} answers 1 value, got {d}", .{
            self.name, returned.values.len,
        });
        return;
    }
    if (returned.values.len != self.results.len) {
        for (returned.values) |expression| _ = try self.lowerExpression(expression, false);
        try self.fail("luce.sema.return", returned.span, "{s} answers {d} values, got {d}", .{
            self.name, self.results.len, returned.values.len,
        });
        return;
    }

    // One walk, so an operand that splits blocks cannot strand the
    // ones before it — the same rule every other operand run keeps.
    const shaped_run = (try self.lowerOperandsIntoTracking(
        returned.values,
        .{ .places = self.results },
    )) orelse return;
    const values = shaped_run.values;
    const stores = try self.arena().alloc(nodes.StoreKind, values.len);
    const value_nodes = try self.arena().alloc(nodes.NodeRef, values.len);
    for (values, returned.values, 0..) |lowered, expression, position| {
        const value = (try self.fit(lowered, self.results[position])) orelse {
            try self.fail(
                "luce.sema.type",
                expression.span(),
                "value {d} of this return is {s}, and {s} answers {s} there{s}",
                .{
                    position + 1,
                    try self.analyzer.typeName(lowered.value_type),
                    self.name,
                    try self.analyzer.typeName(self.results[position]),
                    try refusals.absenceAdvice(self, lowered.value_type, expression),
                },
            );
            return;
        };
        // Each slot decides its own value-storage store kind, exactly
        // as a single return does (docs/STRINGS.md).
        stores[position] = ledger.ownedForStoreKind(self, value);
        value_nodes[position] = value.node;
    }

    try recorder.recordStatement(self, .{ .return_ = .{
        .values = value_nodes,
        .stores = stores,
        .span = returned.span,
        .copied = shaped_run.copied,
    } });
}

/// `CALL catch:` and an indented handler — the statement form, for
/// a recovery that is more than one expression — and `CALL catch
/// NAME:`, which hands that handler the error's own words.
fn lowerGuarded(self: *FunctionBuilder, guarded: ast.Guarded) Error!void {
    // The successful statement may change optional-presence facts,
    // but the failing path reaches the handler with the facts from
    // before the call.  Keep both so the merge can retain only
    // what every continuing path proves.
    const entry = try flow.narrowSave(self);
    defer self.temporary().free(entry);

    // The permission reaches the *value* of the statement, which
    // is the first expression either shape lowers: the call
    // itself, or the value side of `place = call()`.
    self.opened = null;
    self.allow_fallible = true;
    // The attempt records into a frame of its own, so the guarded
    // node — not the surrounding block — carries it whole.
    try recorder.openStatementFrame(self);
    try lowerStatement(self, guarded.attempt.*);
    const attempt_recorded = try recorder.closeCaptureFrame(self, guarded.attempt.span());
    self.allow_fallible = false;
    const opened = self.opened orelse {
        // The binding is named in the refusal when there is one:
        // "drop the catch" is advice a reader has to translate into
        // "and the name with it", and the name is half of what they
        // wrote.
        if (guarded.binding) |binding| {
            try self.fail(
                "luce.sema.fallible",
                guarded.span,
                "catch guards a call that can fail, and this statement has none; drop the catch, and {s} with it — there is no error for it to name",
                .{binding.text},
            );
        } else {
            try self.fail(
                "luce.sema.fallible",
                guarded.span,
                "catch guards a call that can fail, and this statement has none; drop the catch",
                .{},
            );
        }
        return;
    };
    self.opened = null;

    const succeeded = try flow.narrowSave(self);
    defer self.temporary().free(succeeded);
    try flow.narrowRestore(self, entry);

    // The binding lives in a scope of its own, wrapped around the
    // handler's: it is not one of the handler's statements, and a
    // `return` or a `break` out of the handler has to release it on
    // the way past like any other local (S1).
    //
    // **The whole read stands in front of `forget`**, copy
    // included.  `error_message` hands back a borrow of the words
    // and the store is what copies them (docs/STRINGS.md), and
    // while those words would in fact survive the clear — `forget`
    // nulls a pointer and the arena holding them goes with the run
    // — writing it this way means nothing here depends on that.
    // The channel is read, copied, and only then emptied.
    // A binding attempt — `let a = risky() catch:` — makes two
    // demands the assignment forms do not.  The name has no value
    // where the handler runs, so it is hidden from the handler's
    // scope; and the handler must always leave (return, error, trap),
    // because falling through would reach a read of a name nothing
    // initialized.  The parser sends the shape here; this is where it
    // is decided (docs/FAILURE.md).
    const bound_name: ?[]const u8 = switch (guarded.attempt.*) {
        .let => |binding| binding.name,
        .variable => |binding| binding.name,
        else => null,
    };
    var hidden: ?context.LocalInfo = null;
    if (bound_name) |name| {
        if (!helpers.alwaysExits(guarded.handler)) {
            try self.fail(
                "luce.sema.catch",
                guarded.handler.span,
                "this catch block can fall through, and {s} would have no value there: end every path with return or error, or write '… catch VALUE'",
                .{name},
            );
        }
        const top = &self.scopes.items[self.scopes.items.len - 1];
        if (top.names.fetchRemove(name)) |removed| hidden = removed.value;
    }
    var error_local: ?LocalId = null;
    if (guarded.binding) |binding| {
        try self.pushScope();
        // The binding wears what the call fails with (docs/ERRORS.md
        // R2): the bare `!`'s str, or the declared union `match`
        // reads apart.
        if (try self.declareLocal(binding.text, opened.error_type, false, binding.span)) |local| {
            error_local = local;
        }
        try lowerBlock(self, guarded.handler);
        self.popScope();
    } else {
        try lowerBlock(self, guarded.handler);
    }
    if (bound_name) |name| {
        if (hidden) |info| {
            const top = &self.scopes.items[self.scopes.items.len - 1];
            try top.names.put(self.temporary(), name, info);
        }
    }
    const handler_recorded = self.recorded_block.?;

    // The recorded statement: the attempt whole, the handler, and
    // the error binding when one was written.  The binding scope's
    // storage release is re-derived from the locals table, as a
    // match arm's is (nodes.Statement.Match.Binding).
    if (attempt_recorded) |attempt_statement| {
        const kept = try self.arena().create(nodes.Statement);
        kept.* = attempt_statement;
        try recorder.recordStatement(self, .{ .guarded = .{
            .attempt = kept,
            .handler = handler_recorded,
            .error_local = error_local,
            .span = guarded.span,
        } });
    }

    if (helpers.alwaysExits(guarded.handler)) {
        // Only the successful call reaches the merge.
        try flow.narrowRestore(self, succeeded);
    } else {
        // Current is the handler's state; retain only the facts it
        // shares with the successful assignment/call.
        flow.narrowIntersect(self, succeeded);
    }
}
