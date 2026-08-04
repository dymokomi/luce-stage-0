//! Small standalone helpers shared across the analyzer modules.

const std = @import("std");
const ast = @import("../03_parse.zig").ast;
const vocabulary = @import("../support/vocabulary.zig");
const Span = @import("../01_source.zig").Span;

/// How deep an expression tree this stage will walk before refusing
/// it.  Stage 3 bounds *recursive descent*, which a left-leaning
/// chain never exercises: `1 + 1 + ... + 1` parses with a Pratt loop
/// at depth one and yields a tree as deep as the chain is long.  This
/// stage walks that tree recursively, so it needs a bound of its own
/// or a long enough sum — or an f-string with enough holes, which
/// desugars to exactly such a chain — overflows the native stack.
pub const max_expression_depth: u32 = 400;

/// How many values a struct may **unconditionally** hold once every
/// nested struct field is flattened.  Each one costs an instruction to
/// zero and a register to build, and struct nesting multiplies: a
/// chain of 20 structs with two struct fields each is a million values
/// from forty lines of source.
///
/// "Unconditionally" is the whole of it, and is why an optional field
/// counts as one whatever it holds (`declarations.zig`'s
/// `valueCount`): a plain field's payload is part of what the struct
/// is, an optional field's starts absent and arrives only when a
/// program builds one.  This bound and the struct-cycle check are the
/// same rule at two scales — a struct's unconditional expansion must
/// be finite, and small — and `?` is what turns "must hold" into "may
/// hold" for both.  Objects are the other way to hold bulk data.
pub const max_struct_values: u32 = 4096;

/// A dotted chain of bare names in front of a call, collected
/// inner-to-outer: for geo.Text.width(...) the parts are
/// [width-side first] and the head is "geo".
pub const Chain = struct {
    parts: [3][]const u8,
    count: usize,

    /// The outermost name, borrowed from the AST the chain was walked
    /// out of and valid as long as that arena is.
    pub fn head(self: *const Chain) []const u8 {
        return self.parts[self.count - 1];
    }
};

/// Walk a dotted expression to collect the chain of bare names (up to
/// three deep).  Returns null when any link is not a bare name or field
/// of one — the expression is a value method, not a namespaced call.
pub fn dottedChain(target: *const ast.Expression) ?Chain {
    var chain: Chain = .{ .parts = undefined, .count = 0 };
    var walk = target;
    while (true) {
        switch (walk.*) {
            .name => |name| {
                if (chain.count == 3) return null;
                chain.parts[chain.count] = name.text;
                chain.count += 1;
                return chain;
            },
            .field => |field| {
                if (chain.count == 3) return null;
                chain.parts[chain.count] = field.name;
                chain.count += 1;
                walk = field.target;
            },
            else => return null,
        }
    }
}

/// The comparison this source operator names, in the vocabulary the
/// runtime answers in, or null when it names something else.
pub fn comparisonOf(op: ast.BinaryOp) ?vocabulary.BinaryOp {
    return switch (op) {
        .equal => .equal,
        .not_equal => .not_equal,
        .less => .less,
        .less_equal => .less_equal,
        .greater => .greater,
        .greater_equal => .greater_equal,
        .add,
        .subtract,
        .multiply,
        .divide,
        .remainder,
        .logic_and,
        .logic_or,
        .coalesce,
        .catch_error,
        => null,
    };
}

pub fn compareOrder(op: ast.BinaryOp, a: anytype, b: @TypeOf(a)) bool {
    return switch (op) {
        .equal => a == b,
        .not_equal => a != b,
        .less => a < b,
        .less_equal => a <= b,
        .greater => a > b,
        .greater_equal => a >= b,
        else => unreachable,
    };
}

/// True when this expression tree is deeper than `budget` levels.
/// The recursion stops the instant the budget runs out, so the check
/// itself never uses more native stack than the budget allows — which
/// is the point: it is what makes walking the tree afterwards safe.
pub fn deeperThan(expression: *const ast.Expression, budget: u32) bool {
    if (budget == 0) return true;
    const left = budget - 1;
    return switch (expression.*) {
        .int_literal, .float_literal, .bool_literal, .string_literal, .none_literal, .name => false,
        .field => |field| deeperThan(field.target, left),
        .unary => |unary| deeperThan(unary.operand, left),
        .give => |give| deeperThan(give.operand, left),
        .copy => |copied| deeperThan(copied.operand, left),
        .try_call => |attempt| deeperThan(attempt.operand, left),
        .binary => |binary| deeperThan(binary.left, left) or deeperThan(binary.right, left),
        .call => |call| anyDeeperArgument(call.arguments, left),
        .method => |method| deeperThan(method.target, left) or
            anyDeeperArgument(method.arguments, left),
        .new_object => |new| anyDeeper(new.dims, left),
        .list_literal => |literal| anyDeeper(literal.elements, left),
        .index => |index| deeperThan(index.target, left) or anyDeeper(index.indices, left),
        .slice_range => |slice| deeperThan(slice.target, left) or
            (slice.start != null and deeperThan(slice.start.?, left)) or
            (slice.end != null and deeperThan(slice.end.?, left)),
    };
}

fn anyDeeper(expressions: []const *ast.Expression, budget: u32) bool {
    for (expressions) |expression| {
        if (deeperThan(expression, budget)) return true;
    }
    return false;
}

fn anyDeeperArgument(arguments: []const ast.Argument, budget: u32) bool {
    for (arguments) |argument| {
        if (deeperThan(argument.value, budget)) return true;
    }
    return false;
}

// Literals ------------------------------------------------------------------

/// Parse a decimal integer literal, with the minus sign in front of it
/// already folded in when there is one.
///
/// The sign has to fold *before* the range check or `Int`'s minimum is
/// unwritable: `-9223372036854775808` lexes as a minus and a literal
/// whose magnitude is one past the largest positive Int, so checking
/// the magnitude alone rejects the one number that most needs
/// spelling.  Null means out of range.
pub fn parseIntLiteral(text: []const u8, negated: bool) ?i64 {
    const magnitude = std.fmt.parseInt(u64, text, 10) catch return null;
    if (negated) {
        if (magnitude > @as(u64, std.math.maxInt(i64)) + 1) return null;
        return @intCast(-@as(i128, magnitude));
    }
    if (magnitude > std.math.maxInt(i64)) return null;
    return @intCast(magnitude);
}

/// Parse a float literal, refusing one that is not a finite number.
/// `1e400` parses happily and yields infinity — a value the source
/// never wrote and no later stage can tell from a real one — so it is
/// rejected here rather than silently believed.  Underflow to zero is
/// ordinary IEEE rounding and stays accepted.  Null means malformed or
/// not finite.
pub fn parseFloatLiteral(text: []const u8) ?f64 {
    const parsed = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(parsed)) return null;
    return parsed;
}

/// The codepoint `ord` would read from a string literal, or null when
/// the literal is empty (which traps at run time, so it must not
/// fold).  Source text is valid UTF-8 by stage 1, so decoding cannot
/// fail here — but the fallible form is kept, because believing that
/// in a fold is how a compiler emits a wrong constant.
pub fn ordOfLiteral(decoded: []const u8) ?i64 {
    if (decoded.len == 0) return null;
    const length = std.unicode.utf8ByteSequenceLength(decoded[0]) catch return null;
    if (decoded.len < length) return null;
    const codepoint = std.unicode.utf8Decode(decoded[0..length]) catch return null;
    return codepoint;
}

/// The `s` that makes a counted noun agree: "1 argument", but
/// "0 arguments" and "2 arguments".  A diagnostic that miscounts its
/// own grammar reads like one nobody proofread, and every sentence
/// here that counts something ends up wanting this.
pub fn plural(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}

// Name suggestions ----------------------------------------------------------
//
// "unknown name totl" is a true statement; "did you mean total?" is
// the answer.  rustc's resolver does this and it is most of what
// makes its name errors feel helpful, so we do the same: offer every
// name that was in scope, keep the closest, and stay quiet unless it
// is close enough to be worth saying out loud.

/// Longest name a suggestion is computed for.  Past this the distance
/// table would cost more than the advice is worth, and a typo in a
/// 64-byte identifier is not what the reader needs help with.
const max_suggestion_length = 64;

/// Collects the closest spelling of a name among the candidates it is
/// offered.  `best()` answers null when nothing was close enough — a
/// wrong suggestion is worse than none.
pub const Suggestion = struct {
    wanted: []const u8,
    /// Beyond this distance a candidate is a different word, not a
    /// typo.  A third of the length, rounded down — which also means
    /// names under three characters suggest nothing at all, and that
    /// is deliberate: `z` and `x` are one edit apart and have nothing
    /// whatever to do with each other, so a short name carries too
    /// little signal to guess from.
    tolerance: usize,
    closest: ?[]const u8 = null,
    closest_distance: usize = std.math.maxInt(usize),

    pub fn init(wanted: []const u8) Suggestion {
        return .{ .wanted = wanted, .tolerance = wanted.len / 3 };
    }

    pub fn offer(self: *Suggestion, candidate: []const u8) void {
        if (candidate.len > max_suggestion_length or self.wanted.len > max_suggestion_length) return;
        if (std.mem.eql(u8, candidate, self.wanted)) return;
        const distance = editDistance(self.wanted, candidate, self.tolerance);
        if (distance > self.tolerance) return;
        if (distance >= self.closest_distance) return;
        self.closest = candidate;
        self.closest_distance = distance;
    }

    pub fn offerAll(self: *Suggestion, candidates: []const []const u8) void {
        for (candidates) |candidate| self.offer(candidate);
    }

    pub fn best(self: *const Suggestion) ?[]const u8 {
        return self.closest;
    }
};

/// Levenshtein distance between two short names, abandoned once every
/// live cell exceeds `limit` — callers only ever ask "is this within
/// a few edits", so the exact value past the limit is never read.
/// Returns `limit + 1` for "further than that".
pub fn editDistance(a: []const u8, b: []const u8, limit: usize) usize {
    if (a.len > max_suggestion_length or b.len > max_suggestion_length) return limit + 1;
    const difference = if (a.len > b.len) a.len - b.len else b.len - a.len;
    if (difference > limit) return limit + 1;

    var previous: [max_suggestion_length + 1]usize = undefined;
    var current: [max_suggestion_length + 1]usize = undefined;
    for (0..b.len + 1) |index| previous[index] = index;

    for (a, 0..) |a_byte, a_index| {
        current[0] = a_index + 1;
        var row_best = current[0];
        for (b, 0..) |b_byte, b_index| {
            const substitute = previous[b_index] + @intFromBool(a_byte != b_byte);
            const delete = previous[b_index + 1] + 1;
            const insert = current[b_index] + 1;
            current[b_index + 1] = @min(substitute, @min(delete, insert));
            row_best = @min(row_best, current[b_index + 1]);
        }
        if (row_best > limit) return limit + 1;
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

/// `trap("…")` and `error("…")` never come back, so a block ending in
/// one leaves as surely as one that returns.  Both names are reserved,
/// so nothing a reader declares can wear them.
fn leavesByCall(expression: *const ast.Expression) bool {
    if (expression.* != .call) return false;
    const callee = expression.call.callee;
    return std.mem.eql(u8, callee, "trap") or std.mem.eql(u8, callee, "error");
}

/// Conservative all-paths-return: a block returns when some statement
/// certainly returns; an if returns only when both arms do.  Loops
/// never guarantee a return.
pub fn returnsOnAllPaths(block: ast.Block) bool {
    for (block.statements) |statement| {
        switch (statement) {
            .return_statement => return true,
            .expression => |written| if (leavesByCall(written.value)) return true,
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

/// Conservative all-paths-leave: does control certainly not fall out
/// of the bottom of this block?  Return, break and continue all leave;
/// an if leaves only when both arms do.  What makes an early-return
/// guard narrow the rest of the enclosing block — after
/// `if x == none: return`, the code below runs only where `x` is
/// there.  A wrong "no" costs a diagnostic the reader can work around;
/// a wrong "yes" would be unsound, so loops never count.
pub fn alwaysExits(block: ast.Block) bool {
    for (block.statements) |statement| {
        switch (statement) {
            .return_statement, .break_statement, .continue_statement => return true,
            .expression => |written| if (leavesByCall(written.value)) return true,
            .conditional => |conditional| {
                if (conditional.else_block) |else_block| {
                    if (alwaysExits(conditional.then_block) and
                        alwaysExits(else_block)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

/// What a single statement is, when it is one control leaves and never
/// comes back from — and null when control can fall out of it.
///
/// The name is the word the reader wrote, because a diagnostic about
/// unreachable code has one job: say which line took the control away.
/// An `if` counts only when *both* arms leave, which is `alwaysExits`'
/// rule and is conservative in the safe direction — a missed one costs
/// nothing, a wrong one would refuse a running program.
pub fn exitingStatement(statement: ast.Statement) ?[]const u8 {
    return switch (statement) {
        .return_statement => "return",
        .break_statement => "break",
        .continue_statement => "continue",
        .expression => |written| if (written.value.* == .call and leavesByCall(written.value))
            written.value.call.callee
        else
            null,
        .conditional => |conditional| blk: {
            const otherwise = conditional.else_block orelse break :blk null;
            if (!alwaysExits(conditional.then_block)) break :blk null;
            if (!alwaysExits(otherwise)) break :blk null;
            break :blk "if";
        },
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Int's minimum parses only when the sign folds into the literal" {
    // The magnitude alone is one past the largest positive Int, so
    // checking it before applying the sign makes Int.min unwritable.
    try testing.expectEqual(@as(?i64, null), parseIntLiteral("9223372036854775808", false));
    try testing.expectEqual(@as(?i64, std.math.minInt(i64)), parseIntLiteral("9223372036854775808", true));
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), parseIntLiteral("9223372036854775807", false));
    try testing.expectEqual(@as(?i64, null), parseIntLiteral("9223372036854775809", true));
    try testing.expectEqual(@as(?i64, -1), parseIntLiteral("1", true));
    try testing.expectEqual(@as(?i64, 0), parseIntLiteral("0", true));
}

test "a float literal that is not finite is refused, and underflow is not" {
    try testing.expectEqual(@as(?f64, null), parseFloatLiteral("1e400"));
    try testing.expectEqual(@as(?f64, null), parseFloatLiteral("-1e400"));
    try testing.expectEqual(@as(?f64, 0.0), parseFloatLiteral("1e-400"));
    try testing.expectEqual(@as(?f64, 1.5), parseFloatLiteral("1.5"));
    try testing.expectEqual(@as(?f64, null), parseFloatLiteral("nonsense"));
}

test "ord reads the first codepoint of a literal, and nothing from an empty one" {
    try testing.expectEqual(@as(?i64, 40), ordOfLiteral("("));
    try testing.expectEqual(@as(?i64, 955), ordOfLiteral("\u{03bb}"));
    try testing.expectEqual(@as(?i64, 'a'), ordOfLiteral("abc"));
    try testing.expectEqual(@as(?i64, null), ordOfLiteral(""));
}

test "edit distance stops counting once it is past the limit" {
    try testing.expectEqual(@as(usize, 0), editDistance("total", "total", 3));
    try testing.expectEqual(@as(usize, 1), editDistance("totl", "total", 3));
    try testing.expectEqual(@as(usize, 2), editDistance("comptue", "compute", 3));
    // Past the limit the answer is only "further than that".
    try testing.expect(editDistance("alpha", "omega", 1) > 1);
    try testing.expect(editDistance("a", "abcdefgh", 2) > 2);
}

test "a block leaves only when every path does" {
    const marker: Span = .{ .start = 0, .end = 0 };
    const returned: ast.Statement = .{ .return_statement = .{ .value = null, .span = marker } };
    const broke: ast.Statement = .{ .break_statement = .{ .span = marker } };
    const continued: ast.Statement = .{ .continue_statement = .{ .span = marker } };
    var condition: ast.Expression = .{ .bool_literal = .{ .value = true, .span = marker } };

    var one = [_]ast.Statement{returned};
    try testing.expect(alwaysExits(.{ .statements = &one, .span = marker }));
    var two = [_]ast.Statement{broke};
    try testing.expect(alwaysExits(.{ .statements = &two, .span = marker }));
    var three = [_]ast.Statement{continued};
    try testing.expect(alwaysExits(.{ .statements = &three, .span = marker }));
    try testing.expect(!alwaysExits(.{ .statements = &.{}, .span = marker }));

    // Both arms leave, so the conditional does.
    var then_arm = [_]ast.Statement{returned};
    var else_arm = [_]ast.Statement{broke};
    var both = [_]ast.Statement{.{ .conditional = .{
        .condition = &condition,
        .then_block = .{ .statements = &then_arm, .span = marker },
        .else_block = .{ .statements = &else_arm, .span = marker },
        .span = marker,
    } }};
    try testing.expect(alwaysExits(.{ .statements = &both, .span = marker }));

    // One arm is not both, and a loop guarantees nothing.
    var only_then = [_]ast.Statement{.{ .conditional = .{
        .condition = &condition,
        .then_block = .{ .statements = &then_arm, .span = marker },
        .else_block = null,
        .span = marker,
    } }};
    try testing.expect(!alwaysExits(.{ .statements = &only_then, .span = marker }));
    var body = [_]ast.Statement{returned};
    var loop = [_]ast.Statement{.{ .while_loop = .{
        .condition = &condition,
        .body = .{ .statements = &body, .span = marker },
        .span = marker,
    } }};
    try testing.expect(!alwaysExits(.{ .statements = &loop, .span = marker }));
}

test "a suggestion keeps the closest name, and stays quiet when nothing is close" {
    var close = Suggestion.init("appnd");
    close.offerAll(&.{ "append", "insert", "remove", "pop" });
    try testing.expectEqualStrings("append", close.best().?);

    var nothing = Suggestion.init("hasKey");
    nothing.offerAll(&.{ "has", "get", "remove", "keys" });
    try testing.expectEqual(@as(?[]const u8, null), nothing.best());

    // A one- or two-letter name carries too little signal: `z` is one
    // edit from `x` and means nothing like it.
    var too_short = Suggestion.init("z");
    too_short.offerAll(&.{ "x", "y" });
    try testing.expectEqual(@as(?[]const u8, null), too_short.best());

    // The exact name is never its own suggestion.
    var exact = Suggestion.init("append");
    exact.offerAll(&.{"append"});
    try testing.expectEqual(@as(?[]const u8, null), exact.best());
}
