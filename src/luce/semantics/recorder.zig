//! The typed tree's recording API (hir.zig): the small set of
//! calls the walk makes to write down what it decided.
//!
//! Nodes, operand runs, statements, block frames and locals — every
//! one of them appended as the check reaches it, so the tree the seam
//! hands to `hir/lower.zig` is the walk's own account of itself
//! rather than a second traversal's guess.  It is a file because it is
//! the one place that touches `nodes` in a writing mood: everything
//! else asks it for a `NodeRef` and never builds one by hand, and
//! `finishBody` is the single point where the recording is sealed.

const std = @import("std");
const source_mod = @import("../source.zig");
const types = @import("../support/types.zig");
const mir = @import("../mir.zig");
const nodes = @import("../hir.zig").nodes;
const context = @import("context.zig");
const Error = context.Error;
const Span = source_mod.Span;
const Type = types.Type;
const LocalId = mir.LocalId;

const builder = @import("builder.zig");
const FunctionBuilder = builder.FunctionBuilder;
const Typed = builder.Typed;

/// One open block's recorded statements, while its scope is open.
pub const StatementFrame = struct { statements: std.ArrayList(nodes.Statement) };

/// The integer constant behind a checked expression, when the tree
/// proves one.  Bounds land on `long`, so an integer expression may
/// have one folded `convert` between its literal and the value the
/// slice receives, and a fallible call's answer rides a carried
/// link; looking through exactly those keeps this a proof about
/// the recorded tree rather than a second source-expression folder.
pub fn constantLong(self: *const FunctionBuilder, node: nodes.NodeRef) ?i64 {
    return switch (node.*) {
        .const_integer => |literal| literal.value,
        // A folded file-scope constant materializes as its value
        // does; an integer-family one is a `const_integer`.
        .constant_ref => |use| blk: {
            const info = self.analyzer.constant_infos.items[use.constant];
            break :blk if (info.value == .i64) info.value.i64 else null;
        },
        .convert => |conversion| constantLong(self, conversion.operand),
        .carried_get => |carried| constantLong(self, carried.origin),
        .try_call => |wrapped| constantLong(self, wrapped.call),
        else => null,
    };
}

// The typed tree, recorded while the tape still runs ---------------------
//
// Each converted expression family constructs its node here and
// attaches it to the Typed it answers, changing nothing about what
// is emitted (hir.zig).  Converted so far: literals and reads;
// the operators — binary, compare (the exact cross-ladder and
// absence forms included), unary, short-circuit, coalesce — and
// the implicit numeric widening, recorded as `convert` at
// `widenNumeric`, the one place widening is spelled; the calls:
// every call-shaped arm records one `call` node with its resolved
// callee and its operand batch (`recordCallNode`), and a fallible
// call's branch-crossing reload records as `carried_get` at
// `openFallible`, where the try/catch family will find the link
// already in place; and construction — struct and union members
// (`struct_make`/`variant_make`, carrying a call's OperandBatch
// because named-field construction is the named-argument call
// shape), list and map literals, `new`, slices, `give`/`copy`,
// `spawn`, function values and lambdas, and every constant shape
// `emitConstantValue` materializes.
//
// Three call decisions, stated once.  **Identity conversions
// record no call node**: `long(x)` on a `long` (and `string(s)`)
// emits nothing and answers the operand's own value, so the
// operand's node passes through whole — a call node there would
// make `nodes.provenance` claim fresh storage an identity never
// makes.  **`string(f)` records the `function_name` intrinsic**,
// not a `.conversion`, because a function's name is a borrowless
// constant of the program where conversion-to-string means fresh
// bytes (`str_value`).  **A defaulted argument records the
// constant the declaration supplies**, spanned at the call site
// that omitted it, appended to the batch after the written
// operands in the order the defaults materialize — the node rides
// the `Typed` `emitConstantValue` answers, which is the single
// spelling point for every constant shape, construction-shaped
// defaults included.
//
// And three construction decisions.  **Operand runs carry their
// rewrite flag everywhere a batch is lowered**: the defensive
// borrow copy happens at a literal's elements and a slice's
// bounds exactly as before a call's arguments — one walk lowers
// every batch — so the construction nodes record the same
// per-operand flag a call's batch does (`nodes.Operand`).  The
// spill across a block split is *not* recorded anywhere: it is
// `nodes.splitsBlocks`' exact answer about the recorded operands
// themselves, and lower asks it (hir.zig, coupling #4).  **The `T <: T?` widening is a node
// of its own** (`wrap_optional`), recorded at `fit`, the one place
// promotion is spelled — the wrap emits a real instruction whose
// value has a storage answer of its own, so passing the operand's
// node through would claim the operand's provenance for it.
//
// The fallible family: `try` records `try_call` around the
// operand's carried link, `catch` records `catch_expr` with its
// fallback filed as a value or a leaving call (the `else`
// treatment, at the fallible merge), each carrying the ledger
// floor its failing side releases down to, and the statement form
// records `guarded` with the attempt whole.  The statements: every
// `lowerStatement` arm records its node into the open block frame
// (`recordStatement`), blocks close with their scope's releases
// (`closeStatementFrame`), and `finishBody` assembles
// `nodes.Body` with the locals table `recordLocal` mirrors row
// for row off stage 6's (coupling #5).
//
// And coupling #3, the store family.  **Every store site records
// `ownedForStoreKind`'s decision where it is made** — declare
// inits, the four assign shapes, compound forms, return values —
// and **parks are recorded settled**: `flushTemps` writes each
// temporary's surviving claims onto its value's node after any
// adopting store has retracted the storage half, so the tree
// carries the ledger's answer, never the pre-retraction guess the
// emission then contradicts.  Container element stores at
// append/insert and literal fills deliberately record no per-batch
// flag: the settled park plus the node-kind provenance *is* the
// take-or-copy answer there.

/// Record one node of the typed tree — the walk's whole output
/// now that nothing here emits.  Nodes live in the compile arena,
/// which outlives the walk: `hir/lower.zig` reads the finished
/// `Body` after this builder is gone.
pub fn recordNode(self: *FunctionBuilder, expression: nodes.Expression) Error!nodes.NodeRef {
    const made = try self.arena().create(nodes.Expression);
    made.* = expression;
    return made;
}

/// One operand of a call node while its arm assembles the batch:
/// the operand's node — the written expression, or a default's
/// materialized constant — the declaration slot it fills, and the
/// batch's per-operand decision (nodes.OperandBatch).
pub const RecordedOperand = struct {
    node: nodes.NodeRef,
    slot: u32,
    copied: bool = false,
};

/// Assemble one recorded operand batch — written operands first,
/// in evaluation order, then one entry per defaulted slot in the
/// order the defaults are materialized.  Shared by the call node
/// and the two named-field constructions, whose batch convention
/// is the call's (nodes.OperandBatch).
pub fn recordOperandBatch(
    self: *FunctionBuilder,
    entries: []const RecordedOperand,
    written: usize,
) Error!nodes.OperandBatch {
    const operands = try self.arena().alloc(nodes.NodeRef, entries.len);
    const slots = try self.arena().alloc(u32, entries.len);
    const borrow_copy = try self.arena().alloc(bool, entries.len);
    for (entries, operands, slots, borrow_copy) |entry, *operand, *slot, *copied| {
        operand.* = entry.node;
        slot.* = entry.slot;
        copied.* = entry.copied;
    }
    return .{
        .written = @intCast(written),
        .operands = operands,
        .slots = slots,
        .borrow_copy = borrow_copy,
    };
}

/// Record one `call` node from its resolved callee and assembled
/// operand entries.  `written` is how many leading entries the
/// call site wrote — the batch the walk lowered as one — before
/// the defaulted suffix.
pub fn recordCallNode(
    self: *FunctionBuilder,
    callee: nodes.ResolvedCallee,
    entries: []const RecordedOperand,
    written: usize,
    fallible: bool,
    result: Type,
    span: Span,
) Error!nodes.NodeRef {
    return try recordNode(self, .{ .call = .{
        .callee = callee,
        .operands = try recordOperandBatch(self, entries, written),
        .fallible = fallible,
        .result = result,
        .span = span,
    } });
}

/// The recorded form of one non-permuting operand run — a
/// literal's elements, an array's dimensions, a slice's parts —
/// with the batch flag beside each operand's pre-rewrite node
/// (nodes.Operand).
pub fn recordOperandRun(
    self: *FunctionBuilder,
    values: []const Typed,
    copied: []const bool,
) Error![]nodes.Operand {
    const run = try self.arena().alloc(nodes.Operand, values.len);
    for (values, copied, run) |value, was_copied, *slot| {
        slot.* = .{ .node = value.node, .copied = was_copied };
    }
    return run;
}

/// Open one statement frame: the recorded statements of the block
/// whose scope the caller just pushed.
pub fn openStatementFrame(self: *FunctionBuilder) Error!void {
    try self.recorded_blocks.append(self.temporary(), .{ .statements = .empty });
}

/// How many statements the innermost open frame holds — the number
/// `lowerBlock` reads around each statement to count the gaps.
pub fn recordedStatementCount(self: *const FunctionBuilder) usize {
    const frames = self.recorded_blocks.items;
    return frames[frames.len - 1].statements.items.len;
}

/// Append one recorded statement to the innermost open frame.
pub fn recordStatement(self: *FunctionBuilder, statement: nodes.Statement) Error!void {
    std.debug.assert(self.recorded_blocks.items.len != 0);
    const frame = &self.recorded_blocks.items[self.recorded_blocks.items.len - 1];
    try frame.statements.append(self.temporary(), statement);
}

/// Close the innermost frame into a recorded `Block`, with the
/// innermost scope's releases in emission order — reverse
/// declaration order, exactly `emitScopeEnd`'s, read from the same
/// list at the same moment so the two cannot disagree.
pub fn closeStatementFrame(self: *FunctionBuilder, span: Span) Error!nodes.Block {
    var frame = self.recorded_blocks.pop().?;
    defer frame.statements.deinit(self.temporary());
    const owned = self.scopes.items[self.scopes.items.len - 1].owned.items;
    const releases = try self.arena().alloc(nodes.Release, owned.len);
    for (releases, 0..) |*slot, index| {
        const release = owned[owned.len - 1 - index];
        slot.* = .{ .local = release.local, .storage = release.storage, .objects = release.objects };
    }
    return .{
        .statements = try self.arena().dupe(nodes.Statement, frame.statements.items),
        .releases = releases,
        .span = span,
    };
}

/// Close a frame that captured exactly one statement — the guarded
/// form's attempt — answering it, or null when its family left a
/// gap.  No scope belongs to this frame, so there are no releases
/// to read.
pub fn closeCaptureFrame(self: *FunctionBuilder) ?nodes.Statement {
    var frame = self.recorded_blocks.pop().?;
    defer frame.statements.deinit(self.temporary());
    if (frame.statements.items.len != 1) return null;
    return frame.statements.items[0];
}

/// Declare one slot of the tree's locals table (nodes.Body.locals)
/// and answer its id.  **This table is the local numbering**: the
/// walk allocates every slot — named and hidden alike — in the
/// order it decides them, and `hir.lower` reproduces stage 6's
/// table by walking the same declarations in the same order
/// (hir.zig, coupling #5).
pub fn recordLocal(
    self: *FunctionBuilder,
    name: ?[]const u8,
    local_type: Type,
    owns_storage: bool,
    span: Span,
) Error!LocalId {
    const local: LocalId = @intCast(self.recorded_locals.items.len);
    try self.recorded_locals.append(self.temporary(), .{
        .name = name,
        .local_type = local_type,
        .owns_storage = owns_storage,
        .span = span,
    });
    return local;
}

/// The declared type of a slot — the recorded table's answer.
pub fn localType(self: *const FunctionBuilder, local: LocalId) Type {
    return self.recorded_locals.items[local].local_type;
}

/// Whether a slot owns the string bytes and struct runs it holds —
/// the recorded table's answer, settled: a park an adopting store
/// retracted reads false here (`takeStorage`).
pub fn localOwnsStorage(self: *const FunctionBuilder, local: LocalId) bool {
    return self.recorded_locals.items[local].owns_storage;
}

/// Assemble the typed tree's `Body` from the walk that just
/// finished: the body block's statements and releases, the locals
/// table, and the gap count the flip gates on.  Called by
/// `lowerFunction` once the body block is lowered; nothing
/// consumes the result yet — the flip's lower pass will.
pub fn finishBody(self: *FunctionBuilder) Error!void {
    const block = self.recorded_block orelse return;
    self.recorded_body = .{
        .statements = block.statements,
        .releases = block.releases,
        .locals = try self.arena().dupe(nodes.LocalDecl, self.recorded_locals.items),
        .gaps = self.recorded_gaps,
    };
}
