//! Small standalone helpers shared across the analyzer modules.

const std = @import("std");
const ast = @import("../parse.zig").ast;
const vocabulary = @import("../support/vocabulary.zig");
const Span = @import("../source.zig").Span;
const Type = @import("../support/types.zig").Type;

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
        .floor_divide,
        .modulo,
        .bit_and,
        .bit_or,
        .bit_xor,
        .shift_left,
        .shift_right,
        .logic_and,
        .logic_or,
        .coalesce,
        .catch_error,
        .identity,
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
        .int_literal, .float_literal, .bool_literal, .char_literal, .string_literal, .none_literal, .name => false,
        .field => |field| deeperThan(field.target, left),
        .unary => |unary| deeperThan(unary.operand, left),
        .try_call => |attempt| deeperThan(attempt.operand, left),
        .spawn => |worker| deeperThan(worker.call, left),
        .lambda => |written| deeperThan(written.body, left),
        // The closure body is checked as its synthesized function and gets a
        // fresh depth budget. Only creation-time snapshot expressions belong
        // to the surrounding expression tree.
        .closure => |written| for (written.captures) |capture| {
            if (capture.value) |value| {
                if (deeperThan(value, left)) break true;
            }
        } else false,
        .match_value => |written| blk: {
            if (deeperThan(written.scrutinee, left)) break :blk true;
            for (written.arms) |arm| {
                if (deeperThan(arm.value, left)) break :blk true;
            }
            break :blk if (written.else_value) |value| deeperThan(value, left) else false;
        },
        .binary => |binary| deeperThan(binary.left, left) or deeperThan(binary.right, left),
        .call => |call| anyDeeperArgument(call.arguments, left),
        .value_call => |written| deeperThan(written.callee, left) or
            anyDeeperArgument(written.arguments, left),
        .method => |method| deeperThan(method.target, left) or
            anyDeeperArgument(method.arguments, left),
        .new_object => |new| anyDeeperArgument(new.arguments, left),
        .list_literal => |literal| anyDeeper(literal.elements, left),
        .map_literal => |literal| for (literal.entries) |entry| {
            if (deeperThan(entry.key, left) or deeperThan(entry.value, left)) break true;
        } else false,
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

/// Parse a decimal integer literal at the width it lands on, with the
/// minus sign in front of it already folded in when there is one.
///
/// The sign has to fold *before* the range check or a width's minimum
/// is unwritable: `-9223372036854775808` lexes as a minus and a
/// literal whose magnitude is one past the largest positive `i64`, so
/// checking the magnitude alone rejects the one number that most needs
/// spelling — and the same is true of `-2147483648` at `i32`.
///
/// The answer is carried as an `i128` whatever the landing width. That
/// carrier represents both `i64`'s minimum and `u64`'s maximum without
/// changing their source value before the IR records the declared width.
/// Null means out of that range.
pub fn parseIntLiteral(text: []const u8, negated: bool, lands: Type) ?i128 {
    // Base 0 reads the `0x`/`0b` prefixes and steps over `_`
    // separators — both already validated by the lexer
    // (docs/BITWISE.md R3, D7).  `0o` never arrives: stage 2 refuses
    // octal by name and the compile has already failed.
    const magnitude = std.fmt.parseInt(u64, text, 0) catch return null;
    // The range of the width it landed on, both ends, carried at
    // `i128` so that `i64`'s own extremes are ordinary numbers here.
    // One statement covers every integer width and signedness, including
    // `-9223372036854775808`, whose magnitude is not itself an `i64`.
    const bounds = if (lands.isInteger()) lands.integerRange() else Type.integerRange(.i64);
    const signed: i128 = if (negated) -@as(i128, magnitude) else @as(i128, magnitude);
    if (signed < bounds.low or signed > bounds.high) return null;
    return signed;
}

/// Parse a float literal, refusing one that is not a finite number.
/// `1e400` parses happily and yields infinity — a value the source
/// never wrote and no later stage can tell from a real one — so it is
/// rejected here rather than silently believed.  Underflow to zero is
/// ordinary IEEE rounding and stays accepted.  Null means malformed or
/// not finite.
///
/// **The text is parsed at the width the literal lands on**, never at
/// binary64 and then rounded down to it (docs/TYPES.md §1).  Decimal →
/// binary64 → binary32 is a double rounding and disagrees with the
/// correctly-rounded answer for real inputs; reading the source text
/// once, at the destination width, is the same one line and cannot.
pub fn parseFloatLiteral(text: []const u8, lands: Type) ?f64 {
    // **Decimal straight to the width it lands on**, never through a
    // wider one: parsing to binary64 and then rounding to binary16
    // rounds twice, and the second rounding can move the answer by a
    // whole ulp.  Keeping literals as text is what makes this one
    // line per width instead of a correction (docs/TYPES.md §1).
    const parsed: f64 = switch (lands) {
        .f16 => std.fmt.parseFloat(f16, text) catch return null,
        .f32 => std.fmt.parseFloat(f32, text) catch return null,
        else => std.fmt.parseFloat(f64, text) catch return null,
    };
    if (!std.math.isFinite(parsed)) return null;
    return parsed;
}

/// An **integer** literal's text read as a float, because that is the
/// type it landed on: `let x: f64 = 7`.
///
/// Reads the digits rather than converting `parseIntLiteral`'s result,
/// so a literal too large for an `i64` still lands correctly on a
/// float that has room for it — and so the one rule "a literal is
/// parsed at the width it lands on" has no exception for the integer
/// spelling.  Null means malformed or not finite.
pub fn parseIntLiteralAsFloat(text: []const u8, negated: bool, lands: Type) ?f64 {
    const magnitude: f64 = switch (lands) {
        .f16 => std.fmt.parseFloat(f16, text) catch return null,
        .f32 => std.fmt.parseFloat(f32, text) catch return null,
        else => std.fmt.parseFloat(f64, text) catch return null,
    };
    if (!std.math.isFinite(magnitude)) return null;
    return if (negated) -magnitude else magnitude;
}

/// Whether an expression is a **constant expression over numeric
/// literals** — the one shape that carries no type of its own and no
/// effects either, so the place it lands in may decide its width and
/// it may be lowered in either order.
///
/// A literal, a minus in front of one, or an operator whose two sides
/// are both such expressions.  Nothing else: a named constant has a
/// type already, and so does everything with a call in it.
///
/// Asked by both the lowering walk and the constant folder, because
/// the two must agree about what `2 * 0.1` is (docs/TYPES.md §1).
pub fn isUntypedNumber(expression: *const ast.Expression) bool {
    return switch (expression.*) {
        // A character literal is contextual too (docs/TYPES.md D3): it
        // lands on an integer place when its scalar fits, so beside a
        // typed operand it is a taker of context, not a giver.  With
        // no integer context the landing rule keeps it a `char`.
        .int_literal, .float_literal, .char_literal => true,
        .unary => |unary| unary.op == .negate and isUntypedNumber(unary.operand),
        .binary => |binary| switch (binary.op) {
            .add, .subtract, .multiply, .divide, .floor_divide, .modulo => isUntypedNumber(binary.left) and
                isUntypedNumber(binary.right),
            else => false,
        },
        else => false,
    };
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
fn editDistance(a: []const u8, b: []const u8, limit: usize) usize {
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
    return std.mem.eql(u8, callee, "trap") or
        std.mem.eql(u8, callee, "error") or
        std.mem.eql(u8, callee, "exit");
}

/// A `while true` without a break for this loop cannot fall through.
/// Breaks in nested loops belong to those loops, so the walk descends
/// through conditionals, matches and handlers but stops at every other
/// loop boundary.
fn loopHasBreak(block: ast.Block) bool {
    for (block.statements) |statement| {
        switch (statement) {
            .break_statement => return true,
            .conditional => |conditional| {
                if (loopHasBreak(conditional.then_block)) return true;
                if (conditional.else_block) |else_block| {
                    if (loopHasBreak(else_block)) return true;
                }
            },
            .match => |matched| {
                for (matched.arms) |arm| if (loopHasBreak(arm.body)) return true;
                if (matched.else_block) |else_block| {
                    if (loopHasBreak(else_block)) return true;
                }
            },
            .guarded => |guarded| {
                if (statementHasBreak(guarded.attempt.*)) return true;
                if (loopHasBreak(guarded.handler)) return true;
            },
            // A break below another loop belongs to that loop.
            .while_loop, .for_range, .for_each => {},
            else => {},
        }
    }
    return false;
}

fn statementHasBreak(statement: ast.Statement) bool {
    return switch (statement) {
        .break_statement => true,
        .conditional => |conditional| loopHasBreak(conditional.then_block) or
            (if (conditional.else_block) |else_block| loopHasBreak(else_block) else false),
        .match => |matched| blk: {
            for (matched.arms) |arm| if (loopHasBreak(arm.body)) break :blk true;
            break :blk if (matched.else_block) |else_block| loopHasBreak(else_block) else false;
        },
        .guarded => |guarded| statementHasBreak(guarded.attempt.*) or loopHasBreak(guarded.handler),
        .while_loop, .for_range, .for_each => false,
        else => false,
    };
}

fn neverFallsThrough(loop: ast.While) bool {
    return loop.condition.* == .bool_literal and
        loop.condition.bool_literal.value and
        !loopHasBreak(loop.body);
}

/// Conservative all-paths-return: a block returns when some statement
/// certainly returns; an if returns only when both arms do.  Loops
/// guarantee a return only when their condition is literally `true` and
/// no break can target that loop.
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
            .match => |matched| if (everyArm(matched, returnsOnAllPaths)) return true,
            .while_loop => |loop| if (neverFallsThrough(loop)) return true,
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
/// a wrong "yes" would be unsound, so only a literal infinite loop with
/// no break counts.
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
            .match => |matched| if (everyArm(matched, alwaysExits)) return true,
            .while_loop => |loop| if (neverFallsThrough(loop)) return true,
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
        .match => |matched| if (everyArm(matched, alwaysExits)) "match" else null,
        .while_loop => |loop| if (neverFallsThrough(loop)) "while" else null,
        else => null,
    };
}

/// Whether every way through a `match` satisfies `answers` — every arm,
/// and the `else` when there is one.
///
/// **A match with no `else` has an arm for every member**, which stage
/// 4 has already checked (docs/ENUMS.md R1), so the arms are all the
/// ways through: a dispatch whose arms all return is a dispatch that
/// returns, and the function around it needs no return after it.  When
/// the check failed the program is refused anyway, so being generous
/// here can only cost a second diagnostic on a program that already has
/// one.
fn everyArm(matched: ast.Match, comptime answers: fn (ast.Block) bool) bool {
    if (matched.arms.len == 0) return false;
    for (matched.arms) |arm| {
        if (!answers(arm.body)) return false;
    }
    if (matched.else_block) |otherwise| return answers(otherwise);
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "i64 minimum and u64 maximum retain their full source values" {
    try testing.expectEqual(@as(?i128, null), parseIntLiteral("9223372036854775808", false, .i64));
    try testing.expectEqual(@as(?i128, std.math.minInt(i64)), parseIntLiteral("9223372036854775808", true, .i64));
    try testing.expectEqual(@as(?i128, std.math.maxInt(i64)), parseIntLiteral("9223372036854775807", false, .i64));
    try testing.expectEqual(@as(?i128, null), parseIntLiteral("9223372036854775809", true, .i64));
    try testing.expectEqual(@as(?i128, std.math.maxInt(u64)), parseIntLiteral("18446744073709551615", false, .u64));
    try testing.expectEqual(@as(?i128, null), parseIntLiteral("18446744073709551616", false, .u64));
    try testing.expectEqual(@as(?i128, -1), parseIntLiteral("1", true, .i64));
    try testing.expectEqual(@as(?i128, 0), parseIntLiteral("0", true, .i64));
}

test "a floating literal that is not finite is refused, and underflow is not" {
    try testing.expectEqual(@as(?f64, null), parseFloatLiteral("1e400", .f64));
    try testing.expectEqual(@as(?f64, null), parseFloatLiteral("-1e400", .f64));
    try testing.expectEqual(@as(?f64, 0.0), parseFloatLiteral("1e-400", .f64));
    try testing.expectEqual(@as(?f64, 1.5), parseFloatLiteral("1.5", .f64));
    try testing.expectEqual(@as(?f64, null), parseFloatLiteral("nonsense", .f64));
}

test "an integer literal landing on f64 reads its digits, not an i64" {
    // The ordinary cases agree with parseIntLiteral, sign and all.
    try testing.expectEqual(@as(?f64, 7.0), parseIntLiteralAsFloat("7", false, .f64));
    try testing.expectEqual(@as(?f64, -7.0), parseIntLiteralAsFloat("7", true, .f64));
    try testing.expectEqual(@as(?f64, 0.0), parseIntLiteralAsFloat("0", true, .f64));
    // And the case that is the whole reason it reads the digits: a
    // magnitude past i64's range is not an i64, but it is a valid f64,
    // and the type it landed on is f64.
    try testing.expectEqual(@as(?i128, null), parseIntLiteral("99999999999999999999", false, .i64));
    try testing.expectEqual(@as(?f64, 1e20), parseIntLiteralAsFloat("99999999999999999999", false, .f64));
    // Past every floating width as well is still refused, and so is nonsense.
    try testing.expectEqual(@as(?f64, null), parseIntLiteralAsFloat("1" ++ "0" ** 400, false, .f64));
    try testing.expectEqual(@as(?f64, null), parseIntLiteralAsFloat("nonsense", false, .f64));
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
    const returned: ast.Statement = .{ .return_statement = .{ .values = &.{}, .span = marker } };
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

    // One arm is not both, and a finite loop may not execute at all.
    var only_then = [_]ast.Statement{.{ .conditional = .{
        .condition = &condition,
        .then_block = .{ .statements = &then_arm, .span = marker },
        .else_block = null,
        .span = marker,
    } }};
    try testing.expect(!alwaysExits(.{ .statements = &only_then, .span = marker }));
    var finite_condition: ast.Expression = .{ .bool_literal = .{ .value = false, .span = marker } };
    var body = [_]ast.Statement{returned};
    var loop = [_]ast.Statement{.{ .while_loop = .{
        .condition = &finite_condition,
        .body = .{ .statements = &body, .span = marker },
        .span = marker,
    } }};
    try testing.expect(!alwaysExits(.{ .statements = &loop, .span = marker }));

    // A literal infinite loop with no break cannot reach the block's
    // end, so it is a valid last statement of a value-returning
    // function.  A break restores the ordinary conservative answer.
    var forever_body = [_]ast.Statement{continued};
    var forever = [_]ast.Statement{.{ .while_loop = .{
        .condition = &condition,
        .body = .{ .statements = &forever_body, .span = marker },
        .span = marker,
    } }};
    try testing.expect(returnsOnAllPaths(.{ .statements = &forever, .span = marker }));
    try testing.expect(alwaysExits(.{ .statements = &forever, .span = marker }));

    var break_body = [_]ast.Statement{broke};
    var break_loop = [_]ast.Statement{.{ .while_loop = .{
        .condition = &condition,
        .body = .{ .statements = &break_body, .span = marker },
        .span = marker,
    } }};
    try testing.expect(!returnsOnAllPaths(.{ .statements = &break_loop, .span = marker }));
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

/// Whether one argument is unnamed or names exactly `name` — the
/// whole of name resolution for a surface of one slot (docs/ARGS.md),
/// which is what conversion constructors are. Both passes ask it, so
/// it lives here.
pub fn argumentMayName(argument: ast.Argument, name: []const u8) bool {
    const written = argument.name orelse return true;
    return std.mem.eql(u8, written, name);
}
