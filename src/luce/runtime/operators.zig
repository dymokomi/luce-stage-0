//! Operators and scalar builtins: arithmetic, comparison, negation,
//! the Int/Float conversions, and the pure math intrinsics.
//!
//! Luce arithmetic is checked, and every check here is part of the
//! language rather than a debug aid: integer overflow, division by
//! zero, and `minInt / -1` trap with stable codes, while float
//! arithmetic is plain IEEE 754 and never traps.

const std = @import("std");
const vocabulary = @import("../support/vocabulary.zig");
const heap = @import("heap.zig");
const text = @import("text.zig");
const value = @import("value.zig");

const Error = heap.Error;
const Runtime = heap.Runtime;
const Value = value.Value;

/// One binary operator applied to two values of the same Luce type.
/// Comparison answers a Bool; arithmetic answers the operand type.
pub fn binary(runtime: *Runtime, op: vocabulary.BinaryOp, left: Value, right: Value) Error!Value {
    switch (op) {
        .add, .subtract, .multiply, .divide, .floor_divide, .modulo => {},
        else => return Value.ofBoolean(compare(op, left, right)),
    }

    switch (left.view()) {
        .int => |left_int| {
            const right_int = right.asInt();
            switch (op) {
                .add => {
                    const result = @addWithOverflow(left_int, right_int);
                    if (result[1] != 0) return runtime.fail(.integer_overflow);
                    return Value.ofInt(result[0]);
                },
                .subtract => {
                    const result = @subWithOverflow(left_int, right_int);
                    if (result[1] != 0) return runtime.fail(.integer_overflow);
                    return Value.ofInt(result[0]);
                },
                .multiply => {
                    const result = @mulWithOverflow(left_int, right_int);
                    if (result[1] != 0) return runtime.fail(.integer_overflow);
                    return Value.ofInt(result[0]);
                },
                .divide => {
                    if (right_int == 0) return runtime.fail(.divide_by_zero);
                    if (left_int == std.math.minInt(i64) and right_int == -1) {
                        return runtime.fail(.integer_overflow);
                    }
                    return Value.ofInt(@divTrunc(left_int, right_int));
                },
                // `//` and `%` are the integer pair and they **floor**
                // together (docs/NUMERICS.md §3): `-7 // 3` is `-3`
                // and `-7 % 3` is `2`, so `%` takes the sign of the
                // divisor and `b * (a // b) + (a % b) == a` holds for
                // every pair of operands that does not trap.
                .floor_divide => {
                    if (right_int == 0) return runtime.fail(.divide_by_zero);
                    if (left_int == std.math.minInt(i64) and right_int == -1) {
                        return runtime.fail(.integer_overflow);
                    }
                    return Value.ofInt(@divFloor(left_int, right_int));
                },
                .modulo => {
                    if (right_int == 0) return runtime.fail(.divide_by_zero);
                    // `minInt % -1` is `0` under flooring and cannot
                    // overflow, but `@mod` computes it through a
                    // division that can, so the pair is guarded
                    // together and answers what `//` answers.
                    if (left_int == std.math.minInt(i64) and right_int == -1) {
                        return runtime.fail(.integer_overflow);
                    }
                    return Value.ofInt(@mod(left_int, right_int));
                },
                else => unreachable,
            }
        },
        .float => |left_float| {
            const right_float = right.asFloat();
            // IEEE 754 semantics: division by zero and overflow
            // produce infinities and NaN, never traps.
            const computed: f64 = switch (op) {
                .add => left_float + right_float,
                .subtract => left_float - right_float,
                .multiply => left_float * right_float,
                .divide => left_float / right_float,
                // Float `%` floors with the integer one, or promotion
                // would introduce a discontinuity: `-7 % 3` answering
                // `2` and `-7 % 3.0` answering `-1.0`, with an
                // invisible widening choosing between them.  It
                // imports one known wart with it — floor-mod on
                // floats can return the divisor, `-1e-100 % 1.0`
                // being `1.0` exactly, because the true answer is a
                // hair under 1.0 and rounds up.  Python has lived
                // with it since 2.0; the two operators agreeing is
                // worth more (docs/NUMERICS.md §3).
                .modulo => floorMod(left_float, right_float),
                // And `//` floors with it, for the same reason and to
                // keep the identity above true of Floats as well.  It
                // is IEEE like every other Float operation: `1.0 // 0.0`
                // is `inf`, not a trap.
                .floor_divide => @floor(left_float / right_float),
                else => unreachable,
            };
            return Value.ofFloat(computed);
        },
        .string => |left_string| {
            // The analyzer only admits + for strings.
            return text.concat(runtime, left_string, right.asString());
        },
        else => unreachable,
    }
}

/// Comparison, for every type the analyzer admits one on.  Equality on
/// Bool, structs, and objects; full ordering on Int, Float, and
/// String.
pub fn compare(op: vocabulary.BinaryOp, left: Value, right: Value) bool {
    // Absence, before the payload dispatch below, because absence has
    // no payload to dispatch on.  Two absences are the same absence
    // and an absent value equals nothing present — the answer every
    // language with optionals gives, and the only one under which two
    // structs holding `none` in the same field are equal.
    //
    // A struct reaches this by recursing into a `T?` field, which is
    // the only way `op` can be anything but `.equal`/`.not_equal`
    // here: the analyzer admits ordering on Int, Float and String
    // alone, and `T?` is none of those.  Ordering a `T?` would be a
    // front-end bug, and answering `false` for it is a wrong answer
    // rather than a crash, so it is handled with the rest.
    if (left.isNone() or right.isNone()) {
        const same = left.isNone() and right.isNone();
        return if (op == .equal) same else !same;
    }
    switch (left.view()) {
        .int => |held| {
            const other = right.asInt();
            return switch (op) {
                .equal => held == other,
                .not_equal => held != other,
                .less => held < other,
                .less_equal => held <= other,
                .greater => held > other,
                .greater_equal => held >= other,
                else => unreachable,
            };
        },
        .float => |held| {
            const other = right.asFloat();
            return switch (op) {
                .equal => held == other,
                .not_equal => held != other,
                .less => held < other,
                .less_equal => held <= other,
                .greater => held > other,
                .greater_equal => held >= other,
                else => unreachable,
            };
        },
        .string => |held| {
            const order = std.mem.order(u8, held, right.asString());
            return switch (op) {
                .equal => order == .eq,
                .not_equal => order != .eq,
                .less => order == .lt,
                .less_equal => order != .gt,
                .greater => order == .gt,
                .greater_equal => order != .lt,
                else => unreachable,
            };
        },
        .boolean => |held| {
            const same = held == right.asBoolean();
            return if (op == .equal) same else !same;
        },
        .strukt => |held| {
            var same = true;
            for (held, right.asStruct()) |left_field, right_field| {
                if (!compare(.equal, left_field, right_field)) same = false;
            }
            return if (op == .equal) same else !same;
        },
        .object => |held| {
            // Object equality is identity: same object, not same
            // contents — and the same *object*, not merely the same
            // table row, so a stale handle never equals the handle of
            // whoever moved in after it.
            const same = held.same(right.asObject());
            return if (op == .equal) same else !same;
        },
        // Handled above, before the payload dispatch.
        .none => unreachable,
    }
}

test "a struct holding none compares, in either order, instead of crashing" {
    // Reachable from ordinary source: `Slot(room=none) == Slot(room=none)`
    // recurses into the field.  Absent on the *left* used to hit the
    // `.none` arm below and panic the process; absent on the right read
    // a zeroed payload and got the right answer by accident.
    const absent = Value.none;
    const present = Value.ofInt(5);

    try std.testing.expect(compare(.equal, absent, absent));
    try std.testing.expect(!compare(.not_equal, absent, absent));
    try std.testing.expect(!compare(.equal, absent, present));
    try std.testing.expect(!compare(.equal, present, absent));
    try std.testing.expect(compare(.not_equal, absent, present));
    try std.testing.expect(compare(.not_equal, present, absent));
}

/// Float `%`: the floor modulus, pairing with `//` exactly as the
/// integer operators do (docs/NUMERICS.md §3).
///
/// **Not Zig's `@mod`.**  Zig's integer `@mod` floors and pairs with
/// `@divFloor`, but its *float* `@mod` only forces a non-negative
/// answer: `@mod(7.0, -3.0)` is `1.0` where flooring says `-2.0`.
/// Using it would put the discontinuity promotion is meant to remove
/// back one type over — `7 % -3` answering `-2` and `7 % -3.0`
/// answering `1.0`.  So this is written out, and it is the one shape
/// both engines call.
///
/// The result carries the sign of the **divisor**, zeros included:
/// `-6.0 % 3.0` is `0.0` and `6.0 % -3.0` is `-0.0`, which is the rule
/// stated without an exception and what Python answers.
pub fn floorMod(left: f64, right: f64) f64 {
    const remainder = @rem(left, right);
    // `-0.0 == 0.0`, so this arm catches both zeros and the sign is
    // then taken from the divisor rather than left to `@rem`.
    if (remainder == 0.0) return std.math.copysign(@as(f64, 0.0), right);
    // A NaN remainder compares false with everything, so it falls
    // through the addition below and stays NaN either way.
    if ((remainder < 0.0) != (right < 0.0)) return remainder + right;
    return remainder;
}

test "float % floors with //, and the identity holds" {
    const cases = [_][3]f64{
        // left, right, expected
        .{ 7.0, 3.0, 1.0 },
        .{ -7.0, 3.0, 2.0 },
        .{ 7.0, -3.0, -2.0 },
        .{ -7.0, -3.0, -1.0 },
        .{ 5.5, 2.0, 1.5 },
        .{ -5.5, 2.0, 0.5 },
    };
    for (cases) |case| {
        const left = case[0];
        const right = case[1];
        try std.testing.expectEqual(case[2], floorMod(left, right));
        // `b * (a // b) + (a % b) == a`, the identity the pairing is
        // chosen to keep.
        try std.testing.expectEqual(left, right * @floor(left / right) + floorMod(left, right));
    }

    // Zeros take the divisor's sign, so the rule has no exception.
    try std.testing.expect(!std.math.signbit(floorMod(-6.0, 3.0)));
    try std.testing.expect(std.math.signbit(floorMod(6.0, -3.0)));

    // The wart §3 records and accepts: the true answer is a hair under
    // 1.0 and rounds up to it, so floor-mod can return the divisor.
    try std.testing.expectEqual(@as(f64, 1.0), floorMod(-1e-100, 1.0));

    // Infinities and NaN stay IEEE.
    try std.testing.expectEqual(@as(f64, 5.0), floorMod(5.0, std.math.inf(f64)));
    try std.testing.expectEqual(std.math.inf(f64), floorMod(-5.0, std.math.inf(f64)));
    try std.testing.expect(std.math.isNan(floorMod(std.math.inf(f64), 3.0)));
    try std.testing.expect(std.math.isNan(floorMod(1.0, 0.0)));
}

/// Comparison across the Int/Float line, on the mathematical values
/// rather than on a conversion (docs/NUMERICS.md §5).
///
/// The naive lowering — widen the Int with `sitofp`, then compare —
/// is wrong from exactly 2^53 upward, where an `Int` no longer
/// survives the trip: `9007199254740993 == 9007199254740992.0` is
/// false mathematically and true under widening.  Approximation in
/// `+` is expected; an `==` that answers true for two different
/// numbers is a defect, and ordering has to agree with it or
/// `a == b` and `not (a < b) and not (b < a)` part company.  Python's
/// `float_richcompare` is the reference and reaches the same answers.
///
/// **The Int is always the left operand.**  Stage 4 mirrors the
/// operator when the Float was written first, so there is one shape
/// here and one to prove.
pub fn compareIntFloat(op: vocabulary.BinaryOp, left: i64, right: f64) bool {
    // NaN is unordered with everything, itself included, so only `!=`
    // is true of it — the same answer `compare` gives above.
    if (std.math.isNan(right)) return op == .not_equal;

    const order: std.math.Order = if (right >= 9223372036854775808.0)
        // Past the top of the i64 range the Float wins on magnitude
        // alone; +inf arrives here too.  2^63 is exactly
        // representable, which is what makes `>=` the right edge.
        .lt
    else if (right < -9223372036854775808.0)
        .gt
    else compared: {
        // In range, so the integral part converts exactly and the two
        // integers decide it; a tie is broken by the fraction, whose
        // sign says which side of the whole number the Float sits on.
        const whole = @trunc(right);
        const whole_as_int: i64 = @intFromFloat(whole);
        if (left != whole_as_int) break :compared if (left < whole_as_int) .lt else .gt;
        const fraction = right - whole;
        if (fraction == 0.0) break :compared .eq;
        break :compared if (fraction > 0.0) .lt else .gt;
    };

    return switch (op) {
        .equal => order == .eq,
        .not_equal => order != .eq,
        .less => order == .lt,
        .less_equal => order != .gt,
        .greater => order == .gt,
        .greater_equal => order != .lt,
        // The analyzer emits this intrinsic for comparisons only.
        .add, .subtract, .multiply, .divide, .floor_divide, .modulo => unreachable,
    };
}

test "mixed comparison is exact at 2^53, where widening stops being" {
    const two53: i64 = 9007199254740992;
    const as_float: f64 = 9007199254740992.0;

    // The number that does not survive `sitofp`.
    try std.testing.expect(!compareIntFloat(.equal, two53 + 1, as_float));
    try std.testing.expect(compareIntFloat(.greater, two53 + 1, as_float));
    try std.testing.expect(!compareIntFloat(.less_equal, two53 + 1, as_float));
    // And the one that does.
    try std.testing.expect(compareIntFloat(.equal, two53, as_float));
    try std.testing.expect(compareIntFloat(.less_equal, two53, as_float));

    // Fractions on both sides of zero.
    try std.testing.expect(compareIntFloat(.less, 1, 1.5));
    try std.testing.expect(compareIntFloat(.greater, -1, -1.5));
    try std.testing.expect(compareIntFloat(.equal, 1, 1.0));

    // The infinities and NaN.
    try std.testing.expect(compareIntFloat(.less, std.math.maxInt(i64), std.math.inf(f64)));
    try std.testing.expect(compareIntFloat(.greater, std.math.minInt(i64), -std.math.inf(f64)));
    try std.testing.expect(compareIntFloat(.not_equal, 0, std.math.nan(f64)));
    try std.testing.expect(!compareIntFloat(.equal, 0, std.math.nan(f64)));
    try std.testing.expect(!compareIntFloat(.less, 0, std.math.nan(f64)));
    try std.testing.expect(!compareIntFloat(.greater_equal, 0, std.math.nan(f64)));

    // The i64 edges, where the bound itself is representable.
    try std.testing.expect(compareIntFloat(.equal, std.math.minInt(i64), -9223372036854775808.0));
    try std.testing.expect(compareIntFloat(.less, std.math.maxInt(i64), 9223372036854775808.0));
}

/// Ordering for sort: elements are Int, Float, or String (the
/// analyzer guarantees it).
pub fn orderedBefore(context: void, left: Value, right: Value) bool {
    _ = context;
    return switch (left.view()) {
        .int => |held| held < right.asInt(),
        .float => |held| held < right.asFloat(),
        .string => |held| std.mem.order(u8, held, right.asString()) == .lt,
        else => unreachable,
    };
}

/// Unary `-`.  Negating the smallest i64 has no representable result.
pub fn negate(runtime: *Runtime, operand: Value) Error!Value {
    return switch (operand.view()) {
        .int => |held| if (held == std.math.minInt(i64))
            runtime.fail(.integer_overflow)
        else
            Value.ofInt(-held),
        .float => |held| Value.ofFloat(-held),
        else => unreachable,
    };
}

pub fn logicalNot(operand: Value) Value {
    return Value.ofBoolean(!operand.asBoolean());
}

pub fn intToFloat(operand: Value) Value {
    return Value.ofFloat(@floatFromInt(operand.asInt()));
}

/// `Int(x)` truncates toward zero and traps outside the i64 range —
/// NaN and infinities included.
pub fn floatToInt(runtime: *Runtime, operand: Value) Error!Value {
    const held = operand.asFloat();
    if (std.math.isNan(held) or
        held < -9223372036854775808.0 or
        held >= 9223372036854775808.0)
    {
        return runtime.fail(.conversion_range);
    }
    return Value.ofInt(@intFromFloat(@trunc(held)));
}

// ---------------------------------------------------------------------------
// The pure math builtins
// ---------------------------------------------------------------------------

pub fn absolute(runtime: *Runtime, operand: Value) Error!Value {
    return switch (operand.view()) {
        .int => |held| if (held == std.math.minInt(i64))
            runtime.fail(.integer_overflow)
        else
            Value.ofInt(@intCast(@abs(held))),
        .float => |held| Value.ofFloat(@abs(held)),
        else => unreachable,
    };
}

/// `min` when `wants_minimum`, `max` otherwise — one body, because the
/// two differ by a single comparison.
pub fn extremum(wants_minimum: bool, left: Value, right: Value) Value {
    return switch (left.view()) {
        .int => |held| {
            const other = right.asInt();
            return Value.ofInt(if (wants_minimum) @min(held, other) else @max(held, other));
        },
        .float => |held| {
            const other = right.asFloat();
            return Value.ofFloat(if (wants_minimum) @min(held, other) else @max(held, other));
        },
        else => unreachable,
    };
}

pub fn clamp(held: Value, low: Value, high: Value) Value {
    return switch (held.view()) {
        .int => |middle| Value.ofInt(@min(@max(middle, low.asInt()), high.asInt())),
        .float => |middle| Value.ofFloat(@min(@max(middle, low.asFloat()), high.asFloat())),
        else => unreachable,
    };
}

pub fn squareRoot(operand: Value) Value {
    return Value.ofFloat(@sqrt(operand.asFloat()));
}

pub fn floor(operand: Value) Value {
    return Value.ofFloat(@floor(operand.asFloat()));
}

pub fn ceil(operand: Value) Value {
    return Value.ofFloat(@ceil(operand.asFloat()));
}
