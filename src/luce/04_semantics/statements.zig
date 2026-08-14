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
const source_mod = @import("../01_source.zig");
const ast = @import("../03_parse.zig").ast;
const types = @import("../support/types.zig");
const mir = @import("../06_mir.zig");
const helpers = @import("helpers.zig");
const nodes = @import("../05_hir.zig").nodes;
const effects = @import("effects.zig");
const builtins_mod = @import("builtins.zig");
const builtins = builtins_mod.builtins;
const context = @import("context.zig");
const LocalInfo = context.LocalInfo;
const Error = context.Error;
const Span = source_mod.Span;
const Type = types.Type;
const StructLayout = types.StructLayout;
const LocalId = mir.LocalId;

const assign = @import("assign.zig");
const builder = @import("builder.zig");
const flow = @import("flow.zig");
const ledger = @import("ledger.zig");
const recorder = @import("recorder.zig");
const refusals = @import("refusals.zig");
const naming = @import("naming.zig");
const resolve = @import("resolve.zig");
const shapes = @import("shapes.zig");
const signatures = @import("signatures.zig");
const FunctionBuilder = builder.FunctionBuilder;
const RootFact = flow.RootFact;
const StagedOperandOwner = builder.StagedOperandOwner;
const StorageClass = builder.StorageClass;
const Typed = builder.Typed;

pub fn lowerBlock(self: *FunctionBuilder, block: ast.Block) Error!void {
    try self.pushScope();
    try recorder.openStatementFrame(self);
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
                    binding.span,
                );
            } else {
                try lowerLateDeclaration(
                    self,
                    binding.name,
                    binding.name_span,
                    binding.annotation.?,
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
fn lowerMatch(self: *FunctionBuilder, matched: ast.Match) Error!void {
    const temps_floor = self.temps.items.len;
    const scrutinee = (try self.lowerExpression(matched.scrutinee, false)) orelse return;
    if (scrutinee.value_type == .variant) {
        return lowerVariantMatch(self, matched, scrutinee, temps_floor);
    }
    if (scrutinee.value_type != .enumeration) {
        try self.fail(
            "luce.sema.match",
            matched.scrutinee.span(),
            "match dispatches over an enum or a union, and {s} is neither; chain if and elif for a value whose cases have no names{s}",
            .{
                try self.analyzer.typeName(scrutinee.value_type),
                try refusals.absenceAdvice(self, scrutinee.value_type, matched.scrutinee),
            },
        );
        return;
    }
    const reference = scrutinee.value_type.enumeration;
    const declared = self.analyzer.enums.items[reference.index];

    // Which member each arm names, and which members were named:
    // both are needed before anything is lowered, because whether
    // the *last* arm is a comparison or the fallthrough depends on
    // the whole set.
    const chosen = try self.temporary().alloc(u32, matched.arms.len);
    defer self.temporary().free(chosen);
    const covered = try self.temporary().alloc(bool, declared.members.len);
    defer self.temporary().free(covered);
    @memset(covered, false);
    var usable = true;
    for (matched.arms, chosen) |arm, *slot| {
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
        slot.* = member;
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

    // Facts an arm proves are the arm's own, and one that assigns
    // over a narrowed name unproves it for everybody after
    // (`lowerWhile` widens the same way, for the same reason).
    const entry = try flow.narrowSave(self);
    defer self.temporary().free(entry);
    const root_entry = try flow.rootSave(self);
    defer self.temporary().free(root_entry);
    const joined_roots = try self.temporary().dupe(RootFact, root_entry);
    defer self.temporary().free(joined_roots);
    var has_continuing_root = false;

    // With no else and every member named, the last arm needs no
    // test: it is where a value that matched nothing above must be.
    const fallthrough = matched.else_block == null;
    const tested = if (fallthrough) matched.arms.len - 1 else matched.arms.len;

    const recorded_arms = try self.arena().alloc(nodes.Statement.Match.Arm, matched.arms.len);
    var else_recorded: ?nodes.Block = null;
    for (matched.arms[0..tested], chosen[0..tested], recorded_arms[0..tested]) |arm, member, *recorded_arm| {
        try flow.narrowRestore(self, entry);
        flow.rootRestore(self, root_entry);
        try lowerBlock(self, arm.body);
        recorded_arm.* = .{ .member = member, .bindings = &.{}, .body = self.recorded_block.? };
        if (!helpers.alwaysExits(arm.body)) {
            if (has_continuing_root) flow.rootJoinInto(self, joined_roots) else flow.rootCaptureInto(self, joined_roots);
            has_continuing_root = true;
        }
    }
    try flow.narrowRestore(self, entry);
    flow.rootRestore(self, root_entry);
    if (matched.else_block) |otherwise| {
        try lowerBlock(self, otherwise);
        else_recorded = self.recorded_block.?;
        if (!helpers.alwaysExits(otherwise)) {
            if (has_continuing_root) flow.rootJoinInto(self, joined_roots) else flow.rootCaptureInto(self, joined_roots);
            has_continuing_root = true;
        }
    } else {
        const last = matched.arms[matched.arms.len - 1].body;
        try lowerBlock(self, last);
        recorded_arms[matched.arms.len - 1] = .{
            .member = chosen[matched.arms.len - 1],
            .bindings = &.{},
            .body = self.recorded_block.?,
        };
        if (!helpers.alwaysExits(last)) {
            if (has_continuing_root) flow.rootJoinInto(self, joined_roots) else flow.rootCaptureInto(self, joined_roots);
            has_continuing_root = true;
        }
    }

    try flow.narrowRestore(self, entry);
    for (matched.arms) |arm| flow.widenAssignedIn(self, arm.body);
    if (matched.else_block) |otherwise| flow.widenAssignedIn(self, otherwise);
    if (has_continuing_root) flow.rootRestore(self, joined_roots) else flow.rootRestore(self, root_entry);

    // The scrutinee's temporary dies here, after the arms that read
    // it through the held slot (S3, docs/UNION.md's "the match *is*
    // the statement").  An arm that leaves early releases it on its
    // own way out, from the floor its `return`/`break` records.
    ledger.flushTemps(self, temps_floor);

    try recorder.recordStatement(self, .{ .match = .{
        .scrutinee = scrutinee.node,
        .held = held,
        .arms = recorded_arms,
        .else_body = else_recorded,
        .span = matched.span,
    } });
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

    // Which member each arm names, and which members were named:
    // both are needed before anything is lowered, because whether
    // the *last* arm is a comparison or the fallthrough depends on
    // the whole set.
    const chosen = try self.temporary().alloc(u32, matched.arms.len);
    defer self.temporary().free(chosen);
    const covered = try self.temporary().alloc(bool, declared.members.len);
    defer self.temporary().free(covered);
    @memset(covered, false);
    var usable = true;
    for (matched.arms, chosen) |arm, *slot| {
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
        slot.* = member_index;
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

    // What an arm's payload aliases, for S23's sentence: the
    // scrutinee where it is a bare name, nothing otherwise.
    const owner_name: ?[]const u8 = switch (matched.scrutinee.*) {
        .name => |name| name.text,
        else => null,
    };

    // Facts an arm proves are the arm's own, and one that assigns
    // over a narrowed name unproves it for everybody after.
    const entry = try flow.narrowSave(self);
    defer self.temporary().free(entry);
    const root_entry = try flow.rootSave(self);
    defer self.temporary().free(root_entry);
    const joined_roots = try self.temporary().dupe(RootFact, root_entry);
    defer self.temporary().free(joined_roots);
    var has_continuing_root = false;

    // With no else and every member named, the last arm needs no
    // test: it is where a value that matched nothing above must be.
    const fallthrough = matched.else_block == null;
    const tested = if (fallthrough) matched.arms.len - 1 else matched.arms.len;

    const recorded_arms = try self.arena().alloc(nodes.Statement.Match.Arm, matched.arms.len);
    var arms_recorded = true;
    var else_recorded: ?nodes.Block = null;
    for (matched.arms[0..tested], chosen[0..tested], recorded_arms[0..tested]) |arm, member_index, *recorded_arm| {
        try flow.narrowRestore(self, entry);
        flow.rootRestore(self, root_entry);
        if (try lowerVariantArm(self, variant_index, member_index, arm, held, owner_name)) |lowered_arm| {
            recorded_arm.* = lowered_arm;
        } else arms_recorded = false;
        if (!helpers.alwaysExits(arm.body)) {
            if (has_continuing_root) flow.rootJoinInto(self, joined_roots) else flow.rootCaptureInto(self, joined_roots);
            has_continuing_root = true;
        }
    }
    try flow.narrowRestore(self, entry);
    flow.rootRestore(self, root_entry);
    if (matched.else_block) |otherwise| {
        try lowerBlock(self, otherwise);
        else_recorded = self.recorded_block.?;
        if (!helpers.alwaysExits(otherwise)) {
            if (has_continuing_root) flow.rootJoinInto(self, joined_roots) else flow.rootCaptureInto(self, joined_roots);
            has_continuing_root = true;
        }
    } else {
        const last = matched.arms[matched.arms.len - 1];
        if (try lowerVariantArm(self, variant_index, chosen[matched.arms.len - 1], last, held, owner_name)) |lowered_arm| {
            recorded_arms[matched.arms.len - 1] = lowered_arm;
        } else arms_recorded = false;
        if (!helpers.alwaysExits(last.body)) {
            if (has_continuing_root) flow.rootJoinInto(self, joined_roots) else flow.rootCaptureInto(self, joined_roots);
            has_continuing_root = true;
        }
    }

    try flow.narrowRestore(self, entry);
    for (matched.arms) |arm| flow.widenAssignedIn(self, arm.body);
    if (matched.else_block) |otherwise| flow.widenAssignedIn(self, otherwise);
    if (has_continuing_root) flow.rootRestore(self, joined_roots) else flow.rootRestore(self, root_entry);

    // The scrutinee's temporary dies here, after the arms that read
    // it through the held slot (S3, docs/UNION.md's "the match *is*
    // the statement").  An arm that leaves early releases it on its
    // own way out, from the floor its `return`/`break` records.
    ledger.flushTemps(self, temps_floor);

    if (arms_recorded) {
        try recorder.recordStatement(self, .{ .match = .{
            .scrutinee = scrutinee.node,
            .held = held,
            .arms = recorded_arms,
            .else_body = else_recorded,
            .span = matched.span,
        } });
    }
}

/// One arm's binding list against its member's field list
/// (docs/UNION.md D5): every listed name a field, none twice, and
/// all of them or none — a partial list is refused naming the
/// missing fields the way struct construction already does.
/// False after reporting.
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
    const bound = try self.temporary().alloc(bool, member.fields.len);
    defer self.temporary().free(bound);
    @memset(bound, false);
    for (arm.bindings) |binding| {
        const field_index = member.findField(binding.text) orelse {
            var suggestion = helpers.Suggestion.init(binding.text);
            for (member.fields) |field| suggestion.offer(field.name);
            if (suggestion.best()) |closest| {
                try self.fail("luce.sema.match", binding.span, "{s} is not a field of {s}.{s}; did you mean {s}?", .{
                    binding.text,
                    declared.name,
                    member.name,
                    closest,
                });
                return false;
            }
            try self.fail("luce.sema.match", binding.span, "{s} is not a field of {s}.{s}", .{
                binding.text,
                declared.name,
                member.name,
            });
            return false;
        };
        if (bound[field_index]) {
            try self.fail("luce.sema.match", binding.span, "field {s} bound twice", .{binding.text});
            return false;
        }
        bound[field_index] = true;
    }
    for (bound) |given| {
        if (given) continue;
        var left_out: std.ArrayList(u8) = .empty;
        defer left_out.deinit(self.temporary());
        try context.writeMissingFields(
            &left_out,
            self.temporary(),
            .{ .name = member.name, .fields = member.fields },
            bound,
        );
        try self.fail(
            "luce.sema.match",
            arm.span,
            "this arm of {s}.{s} is missing {s}; an arm binds every field, or write '{s}:' to bind none",
            .{ declared.name, member.name, left_out.items, arm.name },
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
    owner_name: ?[]const u8,
) Error!?nodes.Statement.Match.Arm {
    if (arm.bindings.len == 0) {
        try lowerBlock(self, arm.body);
        return .{ .member = member_index, .bindings = &.{}, .body = self.recorded_block.? };
    }
    const member = self.analyzer.variants.items[variant_index].members[member_index];
    const recorded_bindings = try self.arena().alloc(nodes.Statement.Match.Binding, member.fields.len);
    var bindings_recorded = true;
    try self.pushScope();
    for (member.fields, 0..) |field, field_index| {
        // The binding's own span, for "already declared" messages
        // pointing at the name the reader wrote.
        const declared_at = for (arm.bindings) |binding| {
            if (std.mem.eql(u8, binding.text, field.name)) break binding.span;
        } else arm.name_span;
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
            field.name,
            field.field_type,
            false,
            .alias,
            declared_at,
        )) orelse {
            bindings_recorded = false;
            continue;
        };
        recorded_bindings[field_index] = .{ .local = local, .payload = value.node };
        ledger.storeOwned(self, local, value);
        if (owner_name != null) {
            if (self.findLocal(field.name)) |bound| bound.info.owner_name = owner_name;
        }
    }
    try lowerBlock(self, arm.body);
    const body = self.recorded_block.?;
    self.popScope();
    if (!bindings_recorded) return null;
    return .{ .member = member_index, .bindings = recorded_bindings, .body = body };
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
    span: Span,
) Error!void {
    // A binding whose initializer failed still declares a name the
    // reader meant; remembering it keeps one mistake from
    // producing an "unknown name" per later use.
    var value: Typed = undefined;
    // The annotation said `T?` and the initializer handed over a
    // plain `T`, so the binding starts out present.
    var widened = false;
    if (annotation) |written| {
        const expected = (try resolve.resolveType(self.analyzer, self.module, written)) orelse
            return refusals.forgetName(self, name);
        if (value_expression.* == .none_literal) {
            value = ((try self.lowerTyped(value_expression, expected, span, name)) orelse
                return refusals.forgetName(self, name)).value;
        } else {
            self.wantPlace(expected);
            const initializer = (try self.lowerExpression(value_expression, false)) orelse
                return refusals.forgetName(self, name);
            value = (try self.fit(initializer, expected)) orelse {
                // `let f: double = 1` used to arrive here and be
                // told to write `double(...)`; it widens on its own
                // now (docs/NUMERICS.md).  What is left is two
                // sentences, and which one is true depends on the
                // pair: a `long` into an `int` *has* a conversion
                // and is refused because narrowing is never
                // implicit, while a `string` into an `int` has
                // none at all (docs/TYPES.md §11).
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
            widened = !initializer.value_type.eql(expected);
        }
    } else {
        value = (try self.lowerExpression(value_expression, false)) orelse
            return refusals.forgetName(self, name);
    }
    // A binding that received something fresh (or a give, or a
    // copy) owns the object; receiving another name is an alias
    // (S1, S8).  `var xs: list(T)? = none` owns too, for S40's
    // reason: the binding is established here and whatever a later
    // assignment fills in belongs to its scope — `none` itself
    // owns nothing (S43).
    const owns = shapes.carriesObjects(self.analyzer, value.value_type) and
        (value_expression.* == .none_literal or try self.yieldsOwnership(value_expression));
    const local = (try self.declareLocal(
        name,
        value.value_type,
        mutable,
        if (owns) .owned else .alias,
        name_span,
    )) orelse return refusals.forgetName(self, name);
    flow.setRoot(self, local, value.root);
    const store = ledger.storeOwnedKind(self, local, value);
    if (!owns and value_expression.* == .name) {
        // `let y = x` aliases (S8).  Remember whose object it is,
        // so refusing `give y` can name `x` (S23).
        self.rememberOwnerName(name, value_expression.name.text);
    }
    // `let x: long? = 5` is optional in its type and present in
    // fact, and the reader should not have to test what they just
    // wrote.
    if (widened) try flow.narrow(self, local);
    try recorder.recordStatement(self, .{ .declare = .{
        .local = local,
        .value = value.node,
        .store = store,
        .span = span,
    } });
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
        const carried = shapes.carriesObjects(self.analyzer, field.field_type);
        const local = (try self.declareLocal(
            name.text,
            field.field_type,
            bind.mutable,
            if (carried) .owned else .alias,
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
    // The shape itself never owned the objects its fields carried —
    // each name did, from the moment it was bound — so the
    // temporary must not release them a second time.
    ledger.disownShape(self, received.value.node);
    if (complete) {
        try recorder.recordStatement(self, .{ .destructure = .{
            .locals = locals,
            .value = received.value.node,
            .stores = stores,
            .span = bind.span,
        } });
    }
}

const ExistingTarget = struct {
    name: ast.Name,
    local: LocalId,
    value_type: Type,
    owns_objects: bool,
    owns_storage: bool,
};

const PreparedTarget = struct {
    target: ExistingTarget,
    present: bool,
};

/// Whether `actual` reaches `expected` through the two widenings
/// `fit` applies — the compatibility half of `fit`, for the shaped
/// receives whose per-value fits are re-derived by lower.
fn fitsInto(actual: Type, expected: Type) bool {
    if (actual.eql(expected)) return true;
    if (actual.widensTo(expected)) return true;
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
    if (try self.checkPoisoned(info, name.text, name.span)) return null;
    if (info.iterating) {
        try self.fail(
            "luce.sema.own",
            name.span,
            "{s} is being iterated; reassigning it would free the collection under the loop [OWNERSHIP.md S5, S9]",
            .{name.text},
        );
        return null;
    }
    if (info.carries and info.class != .owned and info.class != .inout_receiver) {
        try self.fail(
            "luce.sema.own",
            name.span,
            "{s} does not own its object and cannot receive a returned one; assign into an owning var [OWNERSHIP.md S8, S12, S45]",
            .{name.text},
        );
        return null;
    }
    return .{
        .name = name,
        .local = info.local,
        .value_type = recorder.localType(self, info.local),
        .owns_objects = info.carries,
        .owns_storage = recorder.localOwnsStorage(self, info.local),
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

    // The right side may itself give/free one of the targets.  A
    // preflight alone must not let assignment revive that poisoned
    // name after the call has consumed it (S10/S29).
    for (targets) |target| {
        const current = self.findLocal(target.name.text).?.info;
        if (try self.checkPoisoned(current, target.name.text, target.name.span)) return;
    }

    const prepared = try self.temporary().alloc(PreparedTarget, targets.len);
    defer self.temporary().free(prepared);
    const stores = try self.arena().alloc(nodes.StoreKind, targets.len);
    for (targets, received.layout.fields, 0..) |target, field, position| {
        // A field read is a view into the shape's run, and the two
        // widenings are the only roads between its type and the
        // target's (`fit`'s rule, decided here and re-derived by
        // lower from the same pair of types).
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
        if (item.target.owns_objects) self.forgetAliasesOwnedBy(item.target.name.text);
        if (item.target.value_type == .optional) {
            if (item.present) try flow.narrow(self, item.target.local) else flow.widen(self, item.target.local);
        }
        if (self.localById(item.target.local)) |info| {
            info.root = .mutable;
            info.revision +%= 1;
        }
    }
    // The targets now own every object the return shape carried;
    // its statement temporary keeps only its own field storage.
    ledger.disownShape(self, received.value.node);
    const target_locals = try self.arena().alloc(LocalId, targets.len);
    for (targets, target_locals) |target, *slot| slot.* = target.local;
    try recorder.recordStatement(self, .{ .assign_many = .{
        .targets = target_locals,
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

/// var name: Type — a late declaration (OWNERSHIP.md S40): the
/// slot starts at the type's zero value; the zero of an object
/// type is the null object, which traps on use until assigned.
fn lowerLateDeclaration(
    self: *FunctionBuilder,
    name: []const u8,
    name_span: Span,
    written: ast.TypeName,
    span: Span,
) Error!void {
    const declared = (try resolve.resolveType(self.analyzer, self.module, written)) orelse
        return refusals.forgetName(self, name);
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
            "a function value has no zero: write {s} = the function it names, or var {s}: ({s})? for a slot that starts empty [BINDING.md D7]",
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
    const local = (try self.declareLocal(name, declared, true, .owned, name_span)) orelse
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
    const root_entry = try flow.rootSave(self);
    defer self.temporary().free(root_entry);

    try flow.applyFacts(self, conditional.condition, true, flow.fact_search_depth);
    try lowerBlock(self, conditional.then_block);
    const then_recorded = self.recorded_block.?;
    const after_then = try flow.narrowSave(self);
    defer self.temporary().free(after_then);
    const roots_after_then = try flow.rootSave(self);
    defer self.temporary().free(roots_after_then);

    try flow.narrowRestore(self, entry);
    flow.rootRestore(self, root_entry);
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
        flow.rootRestore(self, roots_after_then);
        return;
    }
    flow.narrowIntersect(self, after_then);
    flow.rootIntersect(self, roots_after_then);
}

fn lowerWhile(self: *FunctionBuilder, loop: ast.While) Error!void {
    // The body runs before the back edge re-enters the header, so
    // anything it assigns may be absent again on the next pass.
    try flow.prepareLoopFacts(self, loop.body);
    const entry = try flow.narrowSave(self);
    defer self.temporary().free(entry);
    const root_entry = try flow.rootSave(self);
    defer self.temporary().free(root_entry);
    defer flow.rootRestore(self, root_entry);
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
    const root_entry = try flow.rootSave(self);
    defer self.temporary().free(root_entry);
    defer flow.rootRestore(self, root_entry);
    const temps_floor = self.temps.items.len;
    const bounds_run = (try self.lowerOperandsIntoTracking(&.{ loop.start, loop.end }, .nothing, null)) orelse return;
    const bounds = bounds_run.values;
    // Widened *before* the registers are read: a bound written as
    // an `int` reaches a `long` loop by widening, and the counted
    // loop the IR opens is a `long` one (docs/TYPES.md §2).
    if (!try self.widensInto(&bounds[0], .long) or !try self.widensInto(&bounds[1], .long)) {
        try self.fail("luce.sema.type", loop.span, "range bounds must be long", .{});
        return;
    }
    const start = bounds[0];
    const end = bounds[1];
    // Bound temporaries die before the loop starts.
    ledger.flushTemps(self, temps_floor);

    try self.pushScope();
    defer self.popScope();
    const index_local = (try self.declareLocal(loop.name, .long, false, .alias, loop.span)) orelse return;
    // The loop's hidden limit slot, mirrored into the tree's
    // locals table in creation order (lower's counted loop makes
    // it right after the counter's row).
    _ = try recorder.recordLocal(self, null, .long, false, loop.span);

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
    const root_entry = try flow.rootSave(self);
    defer self.temporary().free(root_entry);
    defer flow.rootRestore(self, root_entry);
    const iterable = (try self.lowerExpression(loop.iterable, false)) orelse return;
    const descriptor = self.analyzer.heapOf(iterable.value_type) orelse {
        try self.fail("luce.sema.loop", loop.span, "for iterates a list, a rank-1 array, or a map, not {s}{s}", .{
            try self.analyzer.typeName(iterable.value_type),
            try refusals.absenceAdvice(self, iterable.value_type, loop.iterable),
        });
        return;
    };
    // Each collection has a "position" (a map's key, or a
    // list/array's long index) and a "payload" (a map's value, or
    // the element).  `for x in c:` binds the payload for
    // sequences and the key for maps (Python's habit); `for a, b
    // in c:` binds position then payload.
    var position_type: Type = .long;
    const payload_type: Type = switch (descriptor) {
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
        .file => {
            try self.fail("luce.sema.loop", loop.span, "file is not iterable; read into a buffer with f.read(buffer)", .{});
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
    _ = try recorder.recordLocal(self, null, .long, false, loop.span);

    // Which type each declared name binds at.  Single name:
    // payload for sequences, key for maps.  Two names: first =
    // position, second = payload.
    const two_names = loop.value_name != null;
    const map_like = descriptor == .map;
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
        .alias,
        storage_class,
        loop.span,
    )) orelse return;
    const value_local: ?LocalId = if (two_names)
        (try self.declareLocalAs(
            loop.value_name.?,
            payload_type,
            false,
            .alias,
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

/// Refuse a named object that this frame does not own from leaving
/// as a return value.  Resource graphs deliberately get no `copy`
/// advice: changing the parameter/owner is their only legal exit
/// (S16, S17, S31).  False means the name is owned and may move.
fn refuseBorrowedReturn(
    self: *FunctionBuilder,
    span: Span,
    name: []const u8,
    info: *const LocalInfo,
    value_type: Type,
    already_moved: []const LocalId,
    resource_conflict: bool,
) Error!bool {
    if (info.class == .owned) return false;
    const carries_resource = try shapes.carries(self.analyzer, value_type, .resource);
    switch (info.class) {
        .owned => unreachable,
        .borrow_param => {
            if (carries_resource) {
                if (resource_conflict) {
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "{s} is one borrowed resource graph used by more than one result; it cannot be copied — every resource result needs a distinct owned graph, so change the values or the return shape [OWNERSHIP.md S17, S23, S31, S45]",
                        .{name},
                    );
                } else {
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "{s} is a borrowed parameter and carries a file or task; it cannot be copied — change it to a give parameter and make each call site pass ownership (give NAME for an owning name; fresh values need no verb) [OWNERSHIP.md S13, S14, S17, S31]",
                        .{name},
                    );
                }
            } else {
                try self.fail(
                    "luce.sema.own",
                    span,
                    "{s} is a borrowed parameter; return copy {s}, or take the parameter as give [OWNERSHIP.md S17]",
                    .{ name, name },
                );
            }
        },
        .alias => {
            if (carries_resource) {
                if (self.ownerNameFor(info)) |owner| {
                    const owner_info = self.findLocal(owner).?.info;
                    const owner_type = recorder.localType(self, owner_info.local);
                    if (owner_type == .optional and !flow.isNarrowed(self, owner_info.local)) {
                        try self.fail(
                            "luce.sema.own",
                            span,
                            "{s} aliases a resource graph owned by {s}, but that owning binding is not proven present — prove {s} is present, then return the owner; the alias cannot be copied [OWNERSHIP.md S17, S23, S31, S43]",
                            .{ name, owner, owner },
                        );
                    } else if (std.mem.indexOfScalar(LocalId, already_moved, owner_info.local) != null) {
                        try self.fail(
                            "luce.sema.own",
                            span,
                            "{s} aliases a resource graph already returned through {s}; one graph cannot fill two results — return a distinct owned graph or change the return shape [OWNERSHIP.md S23, S31, S45]",
                            .{ name, owner },
                        );
                    } else if (resource_conflict) {
                        try self.fail(
                            "luce.sema.own",
                            span,
                            "{s} aliases the resource graph owned by {s}; every result needs a distinct owned graph — return {s} in only one slot and change the other slot or the return shape [OWNERSHIP.md S16, S17, S23, S31, S45]",
                            .{ name, owner, owner },
                        );
                    } else {
                        try self.fail(
                            "luce.sema.own",
                            span,
                            "{s} aliases a resource graph it does not own; return {s}, the owning name — {s} cannot be copied [OWNERSHIP.md S16, S17, S31]",
                            .{ name, owner, name },
                        );
                    }
                } else {
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "{s} aliases a resource graph it does not own; this borrowed view cannot be copied or moved — obtain an owned value from an ownership-returning operation or redesign the return [OWNERSHIP.md S16, S17, S31]",
                        .{name},
                    );
                }
            } else {
                if (resource_conflict) {
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "{s} aliases an object graph already used by another result; return copy {s} to make a distinct graph, or change the return shape [OWNERSHIP.md S17, S23, S45]",
                        .{ name, name },
                    );
                } else {
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "{s} aliases an object it does not own; return copy {s} or return the owning name [OWNERSHIP.md S16, S17]",
                        .{ name, name },
                    );
                }
            }
        },
        .inout_receiver => {
            if (carries_resource) {
                if (resource_conflict) {
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "self is one caller-owned resource graph used by more than one result; it cannot be copied or moved out — every resource result needs a distinct owned graph, so change the values or the return shape [OWNERSHIP.md S17, S23, S31, S45, SELF.md D4]",
                        .{},
                    );
                } else {
                    try self.fail(
                        "luce.sema.own",
                        span,
                        "self is the caller's receiver and cannot be moved out or copied because it carries a file or task; return a separate give parameter whose caller hands it over [OWNERSHIP.md S17, S31, SELF.md D4]",
                        .{},
                    );
                }
            } else {
                try self.fail(
                    "luce.sema.own",
                    span,
                    "self is the caller's receiver and cannot be moved out; return copy self [OWNERSHIP.md S17, SELF.md D4]",
                    .{},
                );
            }
        },
    }
    return true;
}

/// A visible resource root used by a shaped return.  Unlike
/// `ownerNameFor`, this is identity, not advice: a borrowed
/// parameter and an alias of it still denote the same graph even
/// though neither is a giveable owner.  The prepass lets
/// `return view, owner` and `return borrowed, borrowed` diagnose
/// duplication before suggesting a repair that simply repeats the
/// same graph in another slot (S23, S45).
pub fn visibleOwnershipRoot(
    self: *FunctionBuilder,
    expression: *const ast.Expression,
) Error!?LocalId {
    const named = switch (expression.*) {
        .name => expression,
        .give => |given| given.operand,
        else => return null,
    };
    if (named.* != .name) return null;
    const found = self.findLocal(named.name.text) orelse return null;
    if (!found.info.carries) return null;
    if (found.info.class == .alias) {
        if (found.info.owner_name) |owner| {
            if (self.findLocal(owner)) |root| return root.info.local;
        }
    }
    return found.info.local;
}

/// The owning local visibly at the root of a place expression.
/// Field and index reads remain descendants of their written root;
/// a bare alias recorded by `rememberOwnerName` remains visibly the
/// same root too.  An alias made from a field or index has no such
/// record and deliberately answers its own local: that is the
/// alias-hidden case the runtime backstop must decide (S20, S33).
///
/// A narrowed optional is still a `.name` in the tree, so it takes
/// this same path.  The one expression form that unwraps without a
/// prior narrowing, `x else trap(\"…\")`, keeps `x`'s root because
/// its other arm cannot answer a value.
fn visiblePlaceRoot(
    self: *FunctionBuilder,
    expression: *const ast.Expression,
) Error!?LocalId {
    return switch (expression.*) {
        .name => |name| blk: {
            const found = self.findLocal(name.text) orelse break :blk null;
            if (!found.info.carries) break :blk null;
            if (found.info.class == .alias) {
                if (found.info.owner_name) |owner| {
                    if (self.findLocal(owner)) |root| break :blk root.info.local;
                }
            }
            break :blk found.info.local;
        },
        .field => |field| visiblePlaceRoot(self, field.target),
        .index => |index| visiblePlaceRoot(self, index.target),
        .binary => |binary| blk: {
            if (binary.op != .coalesce) break :blk null;
            const left = try visiblePlaceRoot(self, binary.left);
            const right = try visiblePlaceRoot(self, binary.right);
            if (left != null and right != null and left.? == right.?) break :blk left;
            if (left != null and binary.right.* == .call and
                std.mem.eql(u8, binary.right.call.callee, "trap")) break :blk left;
            break :blk null;
        },
        else => null,
    };
}

const VisibleCycleGive = struct {
    name: []const u8,
    span: Span,
};

/// Whether this bare call is a struct construction.  Written calls
/// have bare names; imported `module.Struct(...)` constructions are
/// method-shaped and answered by `methodConstructsStruct` below.
/// This is intentionally silent: it is consulted only after the
/// ordinary lowering has already resolved and checked the call.
fn callConstructsStruct(self: *FunctionBuilder, call: ast.Call) Error!bool {
    if (std.mem.indexOfScalar(u8, call.callee, '.') != null) return false;
    if (self.findLocal(call.callee) != null) return false;
    const qualified = try naming.qualify(self.analyzer, self.prefix, call.callee);
    return self.analyzer.struct_names.contains(qualified);
}

/// Whether a dotted call is an imported struct construction,
/// silently and without re-running name diagnostics.
fn methodConstructsStruct(self: *FunctionBuilder, method: ast.Method) Error!bool {
    const chain = helpers.dottedChain(method.target) orelse return false;
    const head = chain.head();
    if (self.findLocal(head) != null) return false;

    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(self.temporary());
    var at = chain.count;
    while (at > 0) {
        at -= 1;
        try written.appendSlice(self.temporary(), chain.parts[at]);
        try written.append(self.temporary(), '.');
    }
    try written.appendSlice(self.temporary(), method.name);

    const head_qualified = try naming.qualify(self.analyzer, self.prefix, head);
    if (self.analyzer.struct_names.contains(head_qualified)) {
        const qualified = try naming.qualify(self.analyzer, self.prefix, written.items);
        return self.analyzer.struct_names.contains(qualified);
    }
    if (!naming.importsModule(self.analyzer, self.module, head)) return false;
    return self.analyzer.struct_names.contains(try self.importedName(written.items));
}

/// Find a visible give retained by `expression` itself.  Only the
/// language's definite construction doors recurse: list and map
/// literals and struct construction.  A user call that takes a
/// give argument may release it, transform it, or return another
/// graph, so its result is deliberately left to the runtime rather
/// than guessed here.  `copy` likewise breaks identity and is not
/// traversed (S20, S31, S33).
fn visibleCycleGiveIn(
    self: *FunctionBuilder,
    expression: *const ast.Expression,
    destination: LocalId,
) Error!?VisibleCycleGive {
    return switch (expression.*) {
        .give => |given| blk: {
            const root = (try visibleOwnershipRoot(self, expression)) orelse break :blk null;
            if (root != destination or given.operand.* != .name) break :blk null;
            break :blk .{
                .name = given.operand.name.text,
                .span = given.span,
            };
        },
        .list_literal => |literal| blk: {
            for (literal.elements) |element| {
                if (try visibleCycleGiveIn(self, element, destination)) |found| break :blk found;
            }
            break :blk null;
        },
        .map_literal => |literal| blk: {
            // A map borrows its key and owns its value.
            for (literal.entries) |entry| {
                if (try visibleCycleGiveIn(self, entry.value, destination)) |found| break :blk found;
            }
            break :blk null;
        },
        .call => |call| blk: {
            if (!try callConstructsStruct(self, call)) break :blk null;
            for (call.arguments) |argument| {
                if (try visibleCycleGiveIn(self, argument.value, destination)) |found| break :blk found;
            }
            break :blk null;
        },
        .method => |method| blk: {
            if (!try methodConstructsStruct(self, method)) break :blk null;
            for (method.arguments) |argument| {
                if (try visibleCycleGiveIn(self, argument.value, destination)) |found| break :blk found;
            }
            break :blk null;
        },
        // Either arm may be the value the adopting place keeps.
        .binary => |binary| blk: {
            if (binary.op != .coalesce and binary.op != .catch_error) break :blk null;
            if (try visibleCycleGiveIn(self, binary.left, destination)) |found| break :blk found;
            break :blk try visibleCycleGiveIn(self, binary.right, destination);
        },
        else => null,
    };
}

/// Refuse a statically visible owner entering one of its own
/// descendants.  Runtime ancestry metadata is the authority for
/// aliases stage 4 cannot see; this gate exists to make the direct
/// spelling a compile-time ownership error (S20, S33).
pub fn refuseVisibleOwnershipCycle(
    self: *FunctionBuilder,
    destination: *const ast.Expression,
    retained: *const ast.Expression,
) Error!bool {
    const root = (try visiblePlaceRoot(self, destination)) orelse return false;
    const given = (try visibleCycleGiveIn(self, retained, root)) orelse return false;
    try self.fail(
        "luce.sema.own",
        given.span,
        "giving {s} here would put its owning graph inside one of its own descendants; an owning graph cannot contain itself [OWNERSHIP.md S20, S33]",
        .{given.name},
    );
    return true;
}

fn lowerReturn(self: *FunctionBuilder, returned: ast.Return) Error!void {
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
                .moved = &.{},
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

        // Whatever a function returns, the caller owns (S16, S17):
        // an owned name moves out, fresh values flow out, borrows
        // are compile errors.
        if (shapes.carriesObjects(self.analyzer, value.value_type) and
            try flow.refuseConstantEscape(self, value.root, returned.span, "return")) return;
        var moved_storage: [1]LocalId = undefined;
        var moved: []const LocalId = &.{};
        if (shapes.carriesObjects(self.analyzer, value.value_type)) {
            switch (expression.*) {
                .name => |name| {
                    // The name lowered to a value of an
                    // object-carrying type.  A visible program-root
                    // constant was refused above, so this name is a
                    // local.  Said out loud rather than asserted,
                    // because a compiler that unwraps its beliefs
                    // crashes when one turns out to be wrong.
                    const found = self.findLocal(name.text) orelse return;
                    if (try refuseBorrowedReturn(
                        self,
                        returned.span,
                        name.text,
                        found.info,
                        value.value_type,
                        &.{},
                        false,
                    )) return;
                    moved_storage[0] = found.info.local;
                    moved = moved_storage[0..1];
                },
                else => {
                    if (!(try self.yieldsOwnership(expression))) {
                        if (try shapes.carries(self.analyzer, value.value_type, .resource)) {
                            try self.fail(
                                "luce.sema.own",
                                returned.span,
                                "this resource graph is borrowed from a container or struct and cannot be copied or moved from this view; obtain an owned value from an ownership-returning operation or redesign the return [OWNERSHIP.md S17, S22, S31]",
                                .{},
                            );
                        } else {
                            try self.fail(
                                "luce.sema.own",
                                returned.span,
                                "this object is borrowed from a container or struct; return a copy [OWNERSHIP.md S17, S22]",
                                .{},
                            );
                        }
                        return;
                    }
                    // The fresh return value was parked as a
                    // statement temporary; the object in it moves
                    // to the caller, so the return's unwinding
                    // must not free it.  Its *storage* still goes
                    // back: the return takes a copy of that
                    // (docs/STRINGS.md).  The park rode the
                    // pre-fit node, which any `T <: T?` widening
                    // left untouched.
                    ledger.disownTemp(self, lowered.node);
                },
            }
        }
        // Whatever a string-returning function hands back may be
        // a view of a parameter (`strings.trim` returns
        // `s[first:last]`) or of a local this frame is about to
        // release, and Luce has no annotation that tells them
        // apart — so the return channel copies, except where the
        // value is provably this statement's own; the export of
        // whatever text rides out is lower's, from `carriesText`
        // (docs/STRINGS.md).
        const handed = ledger.ownedForStoreKind(self, value);
        const values = try self.arena().alloc(nodes.NodeRef, 1);
        values[0] = value.node;
        const stores = try self.arena().alloc(nodes.StoreKind, 1);
        stores[0] = handed;
        try recorder.recordStatement(self, .{ .return_ = .{
            .values = values,
            .moved = try self.arena().dupe(LocalId, moved),
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
        .moved = &.{},
        .stores = &.{},
        .span = returned.span,
    } });
}

/// `return a, b` applies the ordinary per-value S16/S17 move rules,
/// then adds the shaped channel's two cross-slot facts: one graph
/// cannot fill two results, and a later operand cannot give or
/// replace an owned name whose old value was already staged for an
/// earlier result (OWNERSHIP.md S23, S45).
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

    // Preflight visible roots before lowering: `return xs, give
    // xs` otherwise loads the first handle and poisons the name
    // only while lowering the second operand, allowing two caller
    // bindings to receive one object.  A give spelling is the one
    // form the ordinary post-lowering duplicate-name check cannot
    // recover (S23, S45).
    const resource_roots = try self.arena().alloc(?LocalId, returned.values.len);
    const resource_conflicts = try self.arena().alloc(bool, returned.values.len);
    @memset(resource_conflicts, false);
    for (returned.values, resource_roots) |expression, *root| {
        root.* = try visibleOwnershipRoot(self, expression);
    }
    for (resource_roots, 0..) |root, position| {
        const wanted = root orelse continue;
        for (resource_roots, 0..) |other, other_position| {
            if (position != other_position and other != null and other.? == wanted) {
                resource_conflicts[position] = true;
                break;
            }
        }
    }
    for (returned.values, self.results, resource_conflicts) |expression, result_type, conflict| {
        if (!conflict or expression.* != .give) continue;
        const operand = expression.give.operand;
        if (operand.* != .name) continue;
        const found = self.findLocal(operand.name.text) orelse continue;
        if (found.info.class != .owned or found.info.poisoned != null or
            self.declaredOutsideActiveLoop(found.depth)) continue;
        const local_type = recorder.localType(self, found.info.local);
        if (local_type == .optional and !flow.isNarrowed(self, found.info.local)) continue;
        const given_type = local_type.held() orelse local_type;
        if (!given_type.eql(result_type) and !given_type.widensTo(result_type)) continue;
        try self.fail(
            "luce.sema.own",
            expression.span(),
            "one object graph is used by more than one return result, including this give; one graph cannot be owned twice — supply distinct owned graphs or change the return shape [OWNERSHIP.md S23, S45]",
            .{},
        );
        return;
    }

    // One walk, so an operand that splits blocks cannot strand the
    // ones before it — the same rule every other operand run keeps.
    const staged_owners = try self.arena().alloc(?StagedOperandOwner, returned.values.len);
    const shaped_run = (try self.lowerOperandsIntoTracking(
        returned.values,
        .{ .places = self.results },
        staged_owners,
    )) orelse return;
    const values = shaped_run.values;
    const fitted_values = try self.arena().alloc(Typed, values.len);
    // Type errors retain precedence over cross-operand ownership
    // effects.  Fit every staged result first, then ask whether a
    // later operand poisoned or replaced one of the names.
    for (values, returned.values, 0..) |lowered, expression, position| {
        fitted_values[position] = (try self.fit(lowered, self.results[position])) orelse {
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
    }
    // A later operand may hand over a binding loaded by an earlier
    // bare-name result through a nested call (`return xs,
    // hand(give xs)`).  Recheck after the whole operand batch so a
    // staged register can never outlive the ownership move that
    // happened to its right (S10, S23, S45).
    for (returned.values) |expression| {
        if (expression.* != .name) continue;
        const found = self.findLocal(expression.name.text) orelse continue;
        if (!found.info.carries) continue;
        if (try self.checkPoisoned(found.info, expression.name.text, expression.span())) return;
    }
    for (staged_owners, returned.values) |maybe_staged, expression| {
        const staged = maybe_staged orelse continue;
        const current = self.localById(staged.local) orelse continue;
        if (current.revision == staged.revision) continue;
        try self.fail(
            "luce.sema.own",
            expression.span(),
            "{s} was replaced by a later return expression after its old value was staged; evaluate the writing operation first, then return distinct current values [OWNERSHIP.md S5, S23, S45, SELF.md D3]",
            .{staged.name},
        );
        return;
    }

    var moved: std.ArrayList(LocalId) = .empty;
    defer moved.deinit(self.temporary());
    const stores = try self.arena().alloc(nodes.StoreKind, fitted_values.len);
    for (fitted_values, returned.values, 0..) |value, expression, position| {
        stores[position] = (try movesOut(
            self,
            expression,
            value,
            &moved,
            resource_conflicts[position],
        )) orelse return;
    }

    const value_nodes = try self.arena().alloc(nodes.NodeRef, fitted_values.len);
    for (fitted_values, value_nodes) |value, *slot| slot.* = value.node;
    try recorder.recordStatement(self, .{ .return_ = .{
        .values = value_nodes,
        .moved = try self.arena().dupe(LocalId, moved.items),
        .stores = stores,
        .span = returned.span,
        .copied = shaped_run.copied,
    } });
}

/// One position of a `return a, b`: check that this value may
/// leave, record the binding whose object it takes with it, and
/// answer how the shape's slot took its storage.  Null after
/// reporting.
fn movesOut(
    self: *FunctionBuilder,
    expression: *const ast.Expression,
    value: Typed,
    moved: *std.ArrayList(LocalId),
    resource_conflict: bool,
) Error!?nodes.StoreKind {
    if (!shapes.carriesObjects(self.analyzer, value.value_type)) {
        return ledger.ownedForStoreKind(self, value);
    }
    if (try flow.refuseConstantEscape(self, value.root, expression.span(), "return")) return null;
    switch (expression.*) {
        .name => |name| {
            const found = self.findLocal(name.text) orelse return null;
            if (try refuseBorrowedReturn(
                self,
                expression.span(),
                name.text,
                found.info,
                value.value_type,
                moved.items,
                resource_conflict,
            )) return null;
            // The genuinely new check.  `return` is a terminator,
            // so with one value there was never anything after it
            // to poison — the comma is what puts something after
            // a return for the first time (docs/RETURNS.md §3).
            if (std.mem.indexOfScalar(LocalId, moved.items, found.info.local) != null) {
                try self.fail(
                    "luce.sema.own",
                    expression.span(),
                    "{s} is returned twice; one object cannot be owned twice [OWNERSHIP.md S23, S45]",
                    .{name.text},
                );
                return null;
            }
            try moved.append(self.temporary(), found.info.local);
        },
        else => {
            if (!(try self.yieldsOwnership(expression))) {
                if (try shapes.carries(self.analyzer, value.value_type, .resource)) {
                    try self.fail(
                        "luce.sema.own",
                        expression.span(),
                        "this resource graph is borrowed from a container or struct and cannot be copied or moved from this view; obtain an owned value from an ownership-returning operation or redesign the return [OWNERSHIP.md S17, S22, S31]",
                        .{},
                    );
                } else {
                    try self.fail(
                        "luce.sema.own",
                        expression.span(),
                        "this object is borrowed from a container or struct; return a copy [OWNERSHIP.md S17, S22]",
                        .{},
                    );
                }
                return null;
            }
            ledger.disownTemp(self, value.node);
        },
    }
    return ledger.ownedForStoreKind(self, value);
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
    const root_entry = try flow.rootSave(self);
    defer self.temporary().free(root_entry);

    // The permission reaches the *value* of the statement, which
    // is the first expression either shape lowers: the call
    // itself, or the value side of `place = call()`.
    self.opened = null;
    self.allow_fallible = true;
    // The attempt records into a frame of its own, so the guarded
    // node — not the surrounding block — carries it whole.
    try recorder.openStatementFrame(self);
    try lowerStatement(self, guarded.attempt.*);
    const attempt_recorded = recorder.closeCaptureFrame(self);
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
    const roots_succeeded = try flow.rootSave(self);
    defer self.temporary().free(roots_succeeded);

    _ = opened;
    try flow.narrowRestore(self, entry);
    flow.rootRestore(self, root_entry);

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
    var error_local: ?LocalId = null;
    if (guarded.binding) |binding| {
        try self.pushScope();
        if (try self.declareLocal(binding.text, .string, false, .alias, binding.span)) |local| {
            error_local = local;
        }
        try lowerBlock(self, guarded.handler);
        self.popScope();
    } else {
        try lowerBlock(self, guarded.handler);
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
        flow.rootRestore(self, roots_succeeded);
    } else {
        // Current is the handler's state; retain only the facts it
        // shares with the successful assignment/call.
        flow.narrowIntersect(self, succeeded);
        flow.rootIntersect(self, roots_succeeded);
    }
}
