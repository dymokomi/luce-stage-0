//! Operators and scalar builtins: arithmetic, comparison, negation,
//! the long/double conversions, and the pure math intrinsics.
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
/// Comparison answers a bool; arithmetic answers the operand type.
pub fn binary(runtime: *Runtime, op: vocabulary.BinaryOp, left: Value, right: Value) Error!Value {
    switch (op) {
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
        => {},
        else => return Value.ofBoolean(compare(op, left, right)),
    }

    switch (left.view()) {
        .u8 => |held| return integer(runtime, op, u8, held, right.asU8()),
        .u16 => |held| return integer(runtime, op, u16, held, right.asU16()),
        .u32 => |held| return integer(runtime, op, u32, held, right.asU32()),
        .u64 => |held| return integer(runtime, op, u64, held, right.asU64()),
        .i8 => |held| return integer(runtime, op, i8, held, right.asI8()),
        .i16 => |held| return integer(runtime, op, i16, held, right.asI16()),
        .i32 => |held| return integer(runtime, op, i32, held, right.asI32()),
        .i64 => |held| return integer(runtime, op, i64, held, right.asI64()),
        .f16 => |held| return floating(op, f16, held, right.asF16()),
        .f32 => |held| return floating(op, f32, held, right.asF32()),
        .f64 => |held| return floating(op, f64, held, right.asF64()),
        .str => |left_string| {
            // The analyzer only admits + for strings.
            _ = left_string;
            return text.concat(runtime, left, right);
        },
        .bytes => |left_bytes| {
            _ = left_bytes;
            return text.concat(runtime, left, right);
        },
        else => unreachable,
    }
}

/// Checked integer arithmetic, at whichever of the two widths the
/// operands arrived at.
///
/// The checks are the language and not a debug aid: overflow, division
/// by zero and `minInt // -1` trap with stable codes at **both**
/// widths, so an `int` counter multiplied past 2^31 stops with a
/// location exactly as a `long` past 2^63 does (docs/TYPES.md §4).
/// One body, so the two can never come to differ.
fn integer(runtime: *Runtime, op: vocabulary.BinaryOp, comptime T: type, left: T, right: T) Error!Value {
    const answer = switch (op) {
        .add => @addWithOverflow(left, right),
        .subtract => @subWithOverflow(left, right),
        .multiply => @mulWithOverflow(left, right),
        // `/` never reaches here: it is real division and always
        // answers a float (docs/NUMERICS.md §2), which the IR verifier
        // enforces — `Binary { .divide, .i64 }` is refused before
        // either engine sees it.
        .divide => unreachable,
        // `//` and `%` are the integer pair and they **floor**
        // together (docs/NUMERICS.md §3): `-7 // 3` is `-3` and
        // `-7 % 3` is `2`, so `%` takes the sign of the divisor and
        // `b * (a // b) + (a % b) == a` holds for every pair of
        // operands that does not trap.
        .floor_divide, .modulo => {
            if (right == 0) return runtime.fail(.divide_by_zero);
            // `minInt % -1` is `0` under flooring and cannot overflow,
            // but `@mod` computes it through a division that can, so
            // the pair is guarded together and answers what `//`
            // answers.
            if (comptime @typeInfo(T).int.signedness == .signed) {
                if (left == std.math.minInt(T) and right == -1) {
                    return runtime.fail(.integer_overflow);
                }
            }
            const computed = if (op == .floor_divide)
                @divFloor(left, right)
            else
                @mod(left, right);
            return boxInteger(T, computed);
        },
        // The bit set (docs/BITWISE.md): two's complement on the
        // representation, `>>` arithmetic because the operands are
        // signed, and `<<` transporting bits rather than multiplying —
        // the count is the one thing checked (R2).
        .bit_and => return boxInteger(T, left & right),
        .bit_or => return boxInteger(T, left | right),
        .bit_xor => return boxInteger(T, left ^ right),
        .shift_left, .shift_right => {
            if (comptime @typeInfo(T).int.signedness == .signed) {
                if (right < 0) return runtime.fail(.shift_out_of_range);
            }
            if (right >= @bitSizeOf(T)) {
                return runtime.fail(.shift_out_of_range);
            }
            const count: std.math.Log2Int(T) = @intCast(right);
            if (op == .shift_left) {
                const shifted = @shlWithOverflow(left, count);
                if (shifted[1] != 0) return runtime.fail(.integer_overflow);
                return boxInteger(T, shifted[0]);
            }
            return boxInteger(T, left >> count);
        },
        else => unreachable,
    };
    if (answer[1] != 0) return runtime.fail(.integer_overflow);
    return boxInteger(T, answer[0]);
}

fn boxInteger(comptime T: type, held: T) Value {
    return switch (T) {
        u8 => Value.ofU8(held),
        u16 => Value.ofU16(held),
        u32 => Value.ofU32(held),
        u64 => Value.ofU64(held),
        i8 => Value.ofI8(held),
        i16 => Value.ofI16(held),
        i32 => Value.ofI32(held),
        i64 => Value.ofI64(held),
        else => unreachable,
    };
}

fn boxFloating(comptime T: type, held: T) Value {
    return switch (T) {
        f16 => Value.ofF16(held),
        f32 => Value.ofF32(held),
        f64 => Value.ofF64(held),
        else => unreachable,
    };
}

/// Floating-point arithmetic, at whichever width the operands
/// arrived at: plain IEEE 754, which never traps.
fn floating(op: vocabulary.BinaryOp, comptime T: type, left_float: T, right_float: T) Error!Value {
    // IEEE 754 semantics: division by zero and overflow produce
    // infinities and NaN, never traps.
    const computed: T = switch (op) {
        .add => left_float + right_float,
        .subtract => left_float - right_float,
        .multiply => left_float * right_float,
        .divide => left_float / right_float,
        // `%` floors with the integer one, or promotion
        // would introduce a discontinuity: `-7 % 3` answering
        // `2` and `-7 % 3.0` answering `-1.0`, with an
        // invisible widening choosing between them.  It
        // imports one known wart with it — floor-mod on
        // floats can return the divisor, `-1e-100 % 1.0`
        // being `1.0` exactly, because the true answer is a
        // hair under 1.0 and rounds up.  Python has lived
        // with it since 2.0; the two operators agreeing is
        // worth more (docs/NUMERICS.md §3).
        .modulo => floorMod(T, left_float, right_float),
        // And `//` floors with it, for the same reason and to
        // keep the identity above true of floats as well.  It
        // is IEEE like every other float operation:
        // `1.0 // 0.0` is `inf`, not a trap.
        .floor_divide => @floor(left_float / right_float),
        else => unreachable,
    };
    return boxFloating(T, computed);
}

/// The six comparisons on a number, at any of the four widths.  NaN
/// falls out of the operators themselves — it compares false with
/// everything, `!=` included, which is what IEEE says.
fn ordered(op: vocabulary.BinaryOp, left: anytype, right: @TypeOf(left)) bool {
    return switch (op) {
        .equal => left == right,
        .not_equal => left != right,
        .less => left < right,
        .less_equal => left <= right,
        .greater => left > right,
        .greater_equal => left >= right,
        else => unreachable,
    };
}

/// Comparison, for every type the analyzer admits one on.  Equality on
/// bool, structs, and objects; full ordering on every number and on
/// str.
pub fn compare(op: vocabulary.BinaryOp, left: Value, right: Value) bool {
    if (!left.hasValidRepresentation() or !right.hasValidRepresentation()) return false;
    // Absence, before the payload dispatch below, because absence has
    // no payload to dispatch on.  Two absences are the same absence
    // and an absent value equals nothing present — the answer every
    // language with optionals gives, and the only one under which two
    // structs holding `none` in the same field are equal.
    //
    // A struct reaches this by recursing into a `T?` field, which is
    // the only way `op` can be anything but `.equal`/`.not_equal`
    // here: the analyzer admits ordering on same-typed numbers and str
    // alone, and `T?` is none of those.  Ordering a `T?` would be a
    // front-end bug, and answering `false` for it is a wrong answer
    // rather than a crash, so it is handled with the rest.
    if (left.isNone() or right.isNone()) {
        const same = left.isNone() and right.isNone();
        return if (op == .equal) same else !same;
    }
    // Comparison is also exposed through a C entry point with no trap
    // channel.  Make malformed or mixed representations a false answer
    // instead of letting a payload accessor reinterpret unrelated bits.
    if (left.tag == .str and !left.hasValidStringRepresentation()) return false;
    if (right.tag == .str and !right.hasValidStringRepresentation()) return false;
    if (left.tag == .bytes and !left.hasValidBytesRepresentation()) return false;
    if (right.tag == .bytes and !right.hasValidBytesRepresentation()) return false;
    switch (left.view()) {
        .u8 => |held| return if (right.tag == .u8) ordered(op, held, right.asU8()) else false,
        .u16 => |held| return if (right.tag == .u16) ordered(op, held, right.asU16()) else false,
        .u32 => |held| return if (right.tag == .u32) ordered(op, held, right.asU32()) else false,
        .u64 => |held| return if (right.tag == .u64) ordered(op, held, right.asU64()) else false,
        .i8 => |held| return if (right.tag == .i8) ordered(op, held, right.asI8()) else false,
        .i16 => |held| return if (right.tag == .i16) ordered(op, held, right.asI16()) else false,
        .i32 => |held| return if (right.tag == .i32) ordered(op, held, right.asI32()) else false,
        .i64 => |held| return if (right.tag == .i64) ordered(op, held, right.asI64()) else false,
        .f16 => |held| return if (right.tag == .f16) ordered(op, held, right.asF16()) else false,
        .f32 => |held| return if (right.tag == .f32) ordered(op, held, right.asF32()) else false,
        .f64 => |held| return if (right.tag == .f64) ordered(op, held, right.asF64()) else false,
        .char => |held| return if (right.tag == .char) ordered(op, held, right.asChar()) else false,
        .str => |held| {
            if (right.tag != .str) return false;
            const order = std.mem.order(u8, held, right.asStr());
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
        .bytes => |held| {
            if (right.tag != .bytes) return false;
            const order = std.mem.order(u8, held, right.asBytes());
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
            if (right.tag != .boolean) return false;
            const same = held == right.asBoolean();
            return if (op == .equal) same else !same;
        },
        .strukt => |held| {
            if (right.tag != .strukt) return false;
            const other = right.asStruct();
            // **Two runs of different lengths are different values**,
            // and saying so is what keeps this loop total.  A struct's
            // run has one length per type, so equal lengths are all a
            // well-formed program can present — but a *union* value is
            // a run too, and its payload slots hold a different shape
            // on each arm, so `Cell(what = Shape.at(...))` against
            // `Cell(what = Shape.count(3))` used to walk two runs of
            // unequal length: a panic in a checked build and a read
            // off the end of a slice in an unchecked one.  Comparing a
            // union at all is refused now — in stage 4 wherever `==`
            // reaches one (docs/UNION.md D16) and in the verifier
            // beside it — so nothing here can arrive from source; this
            // is what a damaged module meets instead of undefined
            // behaviour.
            if (held.len != other.len) return op != .equal;
            var same = true;
            for (held, other) |left_field, right_field| {
                if (!compare(.equal, left_field, right_field)) same = false;
            }
            return if (op == .equal) same else !same;
        },
        .object => |held| {
            if (right.tag != .object) return false;
            // Object equality is identity: same object, not same
            // contents — and the same *object*, not merely the same
            // table row, so a stale handle never equals the handle of
            // whoever moved in after it.
            const same = held.same(right.asObject());
            return if (op == .equal) same else !same;
        },
        // Weak handles are internal struct/local storage. Source reads
        // upgrade them before comparison, but recursive comparison of a
        // damaged or legacy field run must remain total. Identity is the
        // only representation-level answer that cannot dereference a dead
        // row or mistake its later occupant for the original target.
        .weak => |held| {
            if (right.tag != .weak) return false;
            const same = held.same(right.asWeak());
            return if (op == .equal) same else !same;
        },
        // A function value has no equality at all (docs/BINDING.md D6):
        // it is the function it names *and* the receiver it may carry,
        // and its type cannot say which, so stage 4 refuses `==` before
        // anything reaches here — wherever a comparison *reaches* one,
        // through a struct field and through a searched element as well
        // as at the top level, which is one walk shared by `==`, `find`
        // and `contains`.  `mir/verify.zig` refuses the same shape in
        // a decoded module, which is what makes this arm unreachable
        // rather than merely unreached.
        .function => return false,
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
    const present = Value.ofI64(5);

    try std.testing.expect(compare(.equal, absent, absent));
    try std.testing.expect(!compare(.not_equal, absent, absent));
    try std.testing.expect(!compare(.equal, absent, present));
    try std.testing.expect(!compare(.equal, present, absent));
    try std.testing.expect(compare(.not_equal, absent, present));
    try std.testing.expect(compare(.not_equal, present, absent));
}

test "two runs of different lengths are different, instead of walking off one" {
    // A union value is a field run whose payload slots hold a different
    // shape on each arm, so a struct holding one used to present two
    // runs of unequal length here: a panic in a checked build and a
    // read past the end of a slice in an unchecked one.  Comparing a
    // union is refused now — in stage 4 wherever `==` reaches one, and
    // in the MIR verifier beside it — so this is what a damaged module
    // meets rather than undefined behaviour.
    var short = [_]Value{Value.ofI64(1)};
    var long = [_]Value{ Value.ofI64(1), Value.ofI64(2) };

    try std.testing.expect(!compare(.equal, Value.ofStruct(&short), Value.ofStruct(&long)));
    try std.testing.expect(!compare(.equal, Value.ofStruct(&long), Value.ofStruct(&short)));
    try std.testing.expect(compare(.not_equal, Value.ofStruct(&short), Value.ofStruct(&long)));
    try std.testing.expect(compare(.not_equal, Value.ofStruct(&long), Value.ofStruct(&short)));
}

test "comparison rejects mixed and malformed payloads without access faults" {
    var malformed = Value.ofInlineText(.str, "x");
    malformed.inline_length = value.inline_capacity + 1;
    try std.testing.expect(!compare(.equal, Value.ofStr("x"), Value.ofI64(0)));
    try std.testing.expect(!compare(.equal, Value.ofI64(0), Value.ofStr("x")));
    try std.testing.expect(!compare(.equal, malformed, Value.ofStr("x")));

    var function_slots = [_]Value{ Value.ofI64(1), Value.none };
    const function = Value.ofFunction(&function_slots);
    try std.testing.expect(!compare(.equal, function, function));
}

/// `%` on doubles: the floor modulus, pairing with `//` exactly as the
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
pub fn floorMod(comptime T: type, left: T, right: T) T {
    const remainder = @rem(left, right);
    // `-0.0 == 0.0`, so this arm catches both zeros and the sign is
    // then taken from the divisor rather than left to `@rem`.
    if (remainder == 0.0) return std.math.copysign(@as(T, 0.0), right);
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
        try std.testing.expectEqual(case[2], floorMod(f64, left, right));
        // `b * (a // b) + (a % b) == a`, the identity the pairing is
        // chosen to keep.
        try std.testing.expectEqual(left, right * @floor(left / right) + floorMod(f64, left, right));
    }

    // Zeros take the divisor's sign, so the rule has no exception.
    try std.testing.expect(!std.math.signbit(floorMod(f64, -6.0, 3.0)));
    try std.testing.expect(std.math.signbit(floorMod(f64, 6.0, -3.0)));

    // The wart §3 records and accepts: the true answer is a hair under
    // 1.0 and rounds up to it, so floor-mod can return the divisor.
    try std.testing.expectEqual(@as(f64, 1.0), floorMod(f64, -1e-100, 1.0));

    // Infinities and NaN stay IEEE.
    try std.testing.expectEqual(@as(f64, 5.0), floorMod(f64, 5.0, std.math.inf(f64)));
    try std.testing.expectEqual(std.math.inf(f64), floorMod(f64, -5.0, std.math.inf(f64)));
    try std.testing.expect(std.math.isNan(floorMod(f64, std.math.inf(f64), 3.0)));
    try std.testing.expect(std.math.isNan(floorMod(f64, 1.0, 0.0)));
}

/// Comparison across the long/double line, on the mathematical values
/// rather than on a conversion (docs/NUMERICS.md §5).
///
/// The naive lowering — widen the long with `sitofp`, then compare —
/// is wrong from exactly 2^53 upward, where an `long` no longer
/// survives the trip: `9007199254740993 == 9007199254740992.0` is
/// false mathematically and true under widening.  Approximation in
/// `+` is expected; an `==` that answers true for two different
/// numbers is a defect, and ordering has to agree with it or
/// `a == b` and `not (a < b) and not (b < a)` part company.  Python's
/// `float_richcompare` is the reference and reaches the same answers.
///
/// **The long is always the left operand.**  Stage 4 mirrors the
/// operator when the double was written first, so there is one shape
/// here and one to prove.
pub fn compareI64F64(op: vocabulary.BinaryOp, left: i64, right: f64) bool {
    // NaN is unordered with everything, itself included, so only `!=`
    // is true of it — the same answer `compare` gives above.
    if (std.math.isNan(right)) return op == .not_equal;

    const order: std.math.Order = if (right >= 9223372036854775808.0)
        // Past the top of the i64 range the double wins on magnitude
        // alone; +inf arrives here too.  2^63 is exactly
        // representable, which is what makes `>=` the right edge.
        .lt
    else if (right < -9223372036854775808.0)
        .gt
    else compared: {
        // In range, so the integral part converts exactly and the two
        // integers decide it; a tie is broken by the fraction, whose
        // sign says which side of the whole number the double sits on.
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
        => unreachable,
    };
}

test "mixed comparison is exact at 2^53, where widening stops being" {
    const two53: i64 = 9007199254740992;
    const as_float: f64 = 9007199254740992.0;

    // The number that does not survive `sitofp`.
    try std.testing.expect(!compareI64F64(.equal, two53 + 1, as_float));
    try std.testing.expect(compareI64F64(.greater, two53 + 1, as_float));
    try std.testing.expect(!compareI64F64(.less_equal, two53 + 1, as_float));
    // And the one that does.
    try std.testing.expect(compareI64F64(.equal, two53, as_float));
    try std.testing.expect(compareI64F64(.less_equal, two53, as_float));

    // Fractions on both sides of zero.
    try std.testing.expect(compareI64F64(.less, 1, 1.5));
    try std.testing.expect(compareI64F64(.greater, -1, -1.5));
    try std.testing.expect(compareI64F64(.equal, 1, 1.0));

    // The infinities and NaN.
    try std.testing.expect(compareI64F64(.less, std.math.maxInt(i64), std.math.inf(f64)));
    try std.testing.expect(compareI64F64(.greater, std.math.minInt(i64), -std.math.inf(f64)));
    try std.testing.expect(compareI64F64(.not_equal, 0, std.math.nan(f64)));
    try std.testing.expect(!compareI64F64(.equal, 0, std.math.nan(f64)));
    try std.testing.expect(!compareI64F64(.less, 0, std.math.nan(f64)));
    try std.testing.expect(!compareI64F64(.greater_equal, 0, std.math.nan(f64)));

    // The i64 edges, where the bound itself is representable.
    try std.testing.expect(compareI64F64(.equal, std.math.minInt(i64), -9223372036854775808.0));
    try std.testing.expect(compareI64F64(.less, std.math.maxInt(i64), 9223372036854775808.0));
}

/// Ordering for sort: elements are numbers of any width, or Strings
/// (the analyzer guarantees it).
pub fn orderedBefore(context: void, left: Value, right: Value) bool {
    _ = context;
    return switch (left.view()) {
        .u8 => |held| held < right.asU8(),
        .u16 => |held| held < right.asU16(),
        .u32 => |held| held < right.asU32(),
        .u64 => |held| held < right.asU64(),
        .i8 => |held| held < right.asI8(),
        .i16 => |held| held < right.asI16(),
        .i32 => |held| held < right.asI32(),
        .i64 => |held| held < right.asI64(),
        .f16 => |held| held < right.asF16(),
        .f32 => |held| held < right.asF32(),
        .f64 => |held| held < right.asF64(),
        .char => |held| held < right.asChar(),
        .str => |held| std.mem.order(u8, held, right.asStr()) == .lt,
        .bytes => |held| std.mem.order(u8, held, right.asBytes()) == .lt,
        else => unreachable,
    };
}

/// Unary `-`.  Negating the smallest i64 has no representable result.
/// `~x` — two's complement, so it is `-x - 1` at either width and
/// cannot overflow (docs/BITWISE.md D3).
pub fn bitNot(operand: Value) Value {
    return switch (operand.view()) {
        .u8 => |held| Value.ofU8(~held),
        .u16 => |held| Value.ofU16(~held),
        .u32 => |held| Value.ofU32(~held),
        .u64 => |held| Value.ofU64(~held),
        .i8 => |held| Value.ofI8(~held),
        .i16 => |held| Value.ofI16(~held),
        .i32 => |held| Value.ofI32(~held),
        .i64 => |held| Value.ofI64(~held),
        else => unreachable,
    };
}

pub fn negate(runtime: *Runtime, operand: Value) Error!Value {
    return switch (operand.view()) {
        .i8 => |held| if (held == std.math.minInt(i8))
            runtime.fail(.integer_overflow)
        else
            Value.ofI8(-held),
        .i16 => |held| if (held == std.math.minInt(i16))
            runtime.fail(.integer_overflow)
        else
            Value.ofI16(-held),
        .i32 => |held| if (held == std.math.minInt(i32))
            runtime.fail(.integer_overflow)
        else
            Value.ofI32(-held),
        .i64 => |held| if (held == std.math.minInt(i64))
            runtime.fail(.integer_overflow)
        else
            Value.ofI64(-held),
        // A true sign-bit flip, not `0.0 - x`: the two differ for +0.0.
        .f16 => |held| Value.ofF16(-held),
        .f32 => |held| Value.ofF32(-held),
        .f64 => |held| Value.ofF64(-held),
        else => unreachable,
    };
}

pub fn logicalNot(operand: Value) Value {
    return Value.ofBoolean(!operand.asBoolean());
}

/// Every numeric conversion, from the value's own tag to the tag `to`
/// names — the whole of `byte(x)`, `short(x)`, `int(x)`, `long(x)`,
/// `half(x)`, `float(x)`, `double(x)` and the widenings the language
/// inserts for itself (docs/TYPES.md §3).  Seven types is up to
/// forty-two ordered pairs; what is written below is four functions,
/// because a conversion is a *family* question and only then a width
/// one.
///
/// The runtime speaks tags rather than the program's types, which is
/// all it needs: the source is what the value is carrying and the
/// destination is what the register was declared to hold, and the
/// caller reads the second off the IR.
///
/// Two of the four families can stop the program — a float landing on
/// an integer, and an integer landing on a narrower one — and both
/// answer `conversion_range`.  The other two always have an answer.
pub fn convert(runtime: *Runtime, operand: Value, to: value.Tag) Error!Value {
    if (to == .char) {
        if (!integerTag(operand.tag)) return runtime.fail(.not_owned);
        const scalar = wideInteger(operand);
        if (scalar < 0 or scalar > 0x10ffff or (scalar >= 0xd800 and scalar <= 0xdfff)) {
            return runtime.fail(.bad_codepoint);
        }
        return Value.ofChar(@intCast(scalar));
    }
    if (operand.tag == .char) {
        if (to != .u32) return runtime.fail(.not_owned);
        return Value.ofU32(operand.asChar());
    }
    // Each family is read at its widest member first, which is exact
    // for every source: every integer width fits an `i64`, and `half`
    // and `float` are both exactly representable in `f64`.  So the
    // conversion that follows is the *only* rounding there is, and the
    // double-rounding a decimal → binary64 → binary32 path would have
    // is unreachable by construction (docs/TYPES.md §1's argument, one
    // stage down).
    if (integerTag(operand.tag)) {
        const whole = wideInteger(operand);
        if (integerTag(to)) return narrowInteger(runtime, whole, to);
        return floatFromInteger(whole, to);
    }
    const held = wideFloat(operand);
    if (integerTag(to)) return floatToInteger(runtime, held, to);
    return narrowFloat(held, to);
}

/// Whether a tag names an integer.  `byte` is one of them and is
/// unsigned; the other three are signed (docs/TYPES.md D4).
fn integerTag(tag: value.Tag) bool {
    return switch (tag) {
        .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64 => true,
        .f16, .f32, .f64 => false,
        .none, .boolean, .char, .str, .bytes, .strukt, .function, .object, .weak => unreachable,
    };
}

/// An integer of any width, read at `i64` — exact for all four,
/// with `byte` read as the magnitude its bits are (D4).
fn wideInteger(operand: Value) i128 {
    return switch (operand.tag) {
        .u8 => operand.asU8(),
        .u16 => operand.asU16(),
        .u32 => operand.asU32(),
        .u64 => operand.asU64(),
        .i8 => operand.asI8(),
        .i16 => operand.asI16(),
        .i32 => operand.asI32(),
        .i64 => operand.asI64(),
        else => unreachable,
    };
}

/// A float of any width, read at `f64` — exact for all three.
fn wideFloat(operand: Value) f64 {
    return switch (operand.tag) {
        .f16 => operand.asF16(),
        .f32 => operand.asF32(),
        .f64 => operand.asF64(),
        else => unreachable,
    };
}

/// An integer landing on an integer: outside the destination's range
/// it stops, because `int(3000000000)` is not three billion modulo
/// anything and `byte(300)` is not 44.  A widening cannot fail and
/// takes the same path, which is what keeps one statement of the
/// bounds rather than one per direction.
fn narrowInteger(runtime: *Runtime, held: i128, to: value.Tag) Error!Value {
    switch (to) {
        .u8 => {
            if (held < 0 or held > std.math.maxInt(u8)) return runtime.fail(.conversion_range);
            return Value.ofU8(@intCast(held));
        },
        .u16 => {
            if (held < 0 or held > std.math.maxInt(u16)) return runtime.fail(.conversion_range);
            return Value.ofU16(@intCast(held));
        },
        .u32 => {
            if (held < 0 or held > std.math.maxInt(u32)) return runtime.fail(.conversion_range);
            return Value.ofU32(@intCast(held));
        },
        .u64 => {
            if (held < 0 or held > std.math.maxInt(u64)) return runtime.fail(.conversion_range);
            return Value.ofU64(@intCast(held));
        },
        .i8 => {
            if (held < std.math.minInt(i8) or held > std.math.maxInt(i8)) {
                return runtime.fail(.conversion_range);
            }
            return Value.ofI8(@intCast(held));
        },
        .i16 => {
            if (held < std.math.minInt(i16) or held > std.math.maxInt(i16)) {
                return runtime.fail(.conversion_range);
            }
            return Value.ofI16(@intCast(held));
        },
        .i32 => {
            if (held < std.math.minInt(i32) or held > std.math.maxInt(i32)) {
                return runtime.fail(.conversion_range);
            }
            return Value.ofI32(@intCast(held));
        },
        .i64 => {
            if (held < std.math.minInt(i64) or held > std.math.maxInt(i64)) {
                return runtime.fail(.conversion_range);
            }
            return Value.ofI64(@intCast(held));
        },
        else => unreachable,
    }
}

/// An integer landing on a float: one `@floatFromInt` straight to the
/// destination width, so there is exactly one rounding.  Never traps —
/// every integer has a nearest float, `inf` included once the
/// magnitude passes the top of a `half`.
fn floatFromInteger(held: i128, to: value.Tag) Value {
    return switch (to) {
        .f16 => Value.ofF16(@floatFromInt(held)),
        .f32 => Value.ofF32(@floatFromInt(held)),
        .f64 => Value.ofF64(@floatFromInt(held)),
        else => unreachable,
    };
}

/// A float landing on a narrower float: rounds to nearest, ties to
/// even, and reaches `inf` rather than trapping — IEEE, with no
/// second story about infinity bolted on.  `double` to `half` is one
/// `@floatCast` and therefore one rounding, not a detour through
/// binary32 (docs/TYPES.md §7).
fn narrowFloat(held: f64, to: value.Tag) Value {
    return switch (to) {
        .f16 => Value.ofF16(@floatCast(held)),
        .f32 => Value.ofF32(@floatCast(held)),
        .f64 => Value.ofF64(held),
        else => unreachable,
    };
}

/// `long(x)` and its four siblings **round half away from zero** and
/// trap outside the destination's range — NaN and infinities included
/// (docs/NUMERICS.md §7).
///
/// Half away from zero, and not IEEE's half-to-even, for one reason
/// that outranks the numerical arguments: `math.round` already
/// existed, was already documented as rounding that way, and is
/// already what `strings.format_float` uses.  A language with two
/// roundings that disagree has a bug in it, and the one already
/// ratified wins.
///
/// The range check is the same one in the same three places — here,
/// the constant folder, and `codegen/lower.zig` — because a
/// conversion that disagrees at the boundary is a different language.
/// It runs **after** the rounding, on what rounding produced: NaN and
/// the infinities survive `@round` unchanged so the one check still
/// catches them, and a value rounding carried past the top of the
/// range is refused rather than wrapped.
fn floatToInteger(runtime: *Runtime, held: f64, to: value.Tag) Error!Value {
    const rounded = @trunc(held);
    // The bottom of the range and *one past* the top, tested with
    // `>=`: every one of those eight bounds is a small integer or a
    // power of two and therefore exact in binary64, while `maxInt`
    // itself is not once the width reaches 64.
    const bounds: struct { lowest: f64, past_top: f64 } = switch (to) {
        .u8 => .{ .lowest = 0.0, .past_top = 256.0 },
        .u16 => .{ .lowest = 0.0, .past_top = 65536.0 },
        .u32 => .{ .lowest = 0.0, .past_top = 4294967296.0 },
        .u64 => .{ .lowest = 0.0, .past_top = 18446744073709551616.0 },
        .i8 => .{ .lowest = -128.0, .past_top = 128.0 },
        .i16 => .{ .lowest = -32768.0, .past_top = 32768.0 },
        .i32 => .{ .lowest = -2147483648.0, .past_top = 2147483648.0 },
        .i64 => .{ .lowest = -9223372036854775808.0, .past_top = 9223372036854775808.0 },
        else => unreachable,
    };
    if (std.math.isNan(rounded) or rounded < bounds.lowest or rounded >= bounds.past_top) {
        return runtime.fail(.conversion_range);
    }
    return switch (to) {
        .u8 => Value.ofU8(@intFromFloat(rounded)),
        .u16 => Value.ofU16(@intFromFloat(rounded)),
        .u32 => Value.ofU32(@intFromFloat(rounded)),
        .u64 => Value.ofU64(@intFromFloat(rounded)),
        .i8 => Value.ofI8(@intFromFloat(rounded)),
        .i16 => Value.ofI16(@intFromFloat(rounded)),
        .i32 => Value.ofI32(@intFromFloat(rounded)),
        .i64 => Value.ofI64(@intFromFloat(rounded)),
        else => unreachable,
    };
}

/// Round half away from zero: `2.5` to `3.0`, `-2.5` to `-3.0`.
///
/// **`floor(x + 0.5)` is not this function**, which is worth writing
/// down because that is how `std/math.luc` used to spell it and how
/// most people would: `0.49999999999999994 + 0.5` rounds *up* to
/// exactly `1.0` in binary64, so the floor of it is `1` where the
/// right answer is `0`.  `@round` is the operation itself — IEEE
/// roundToIntegralTiesToAway, and `llvm.round` on the compiled side —
/// and `math.round` now computes the same thing from `trunc` and a
/// fraction, which is exact.  A language with two roundings that
/// disagree has a bug in it.
pub fn roundHalfAway(comptime T: type, held: T) T {
    return @round(held);
}

test "long(x) rounds half away from zero, on both sides of it" {
    try std.testing.expectEqual(@as(f64, 3.0), roundHalfAway(f64, 2.5));
    try std.testing.expectEqual(@as(f64, -3.0), roundHalfAway(f64, -2.5));
    try std.testing.expectEqual(@as(f64, 1.0), roundHalfAway(f64, 0.5));
    try std.testing.expectEqual(@as(f64, -1.0), roundHalfAway(f64, -0.5));
    try std.testing.expectEqual(@as(f64, 2.0), roundHalfAway(f64, 2.4));
    try std.testing.expectEqual(@as(f64, -2.0), roundHalfAway(f64, -2.4));
    try std.testing.expectEqual(@as(f64, 3.0), roundHalfAway(f64, 2.6));
    try std.testing.expectEqual(@as(f64, -3.0), roundHalfAway(f64, -2.6));
    try std.testing.expectEqual(@as(f64, 0.0), roundHalfAway(f64, 0.0));

    // The value that separates rounding from `floor(x + 0.5)`: at
    // binary64 precision the sum rounds up to exactly 1.0, so the
    // floor of it is 1 where the answer is 0.  Both operands are
    // runtime values, because comptime float arithmetic in Zig is
    // arbitrary-precision and would not reproduce the rounding step
    // that is the whole point.
    var nearly_half: f64 = 0.49999999999999994;
    _ = &nearly_half;
    var half: f64 = 0.5;
    _ = &half;
    try std.testing.expectEqual(@as(f64, 0.0), roundHalfAway(f64, nearly_half));
    try std.testing.expectEqual(@as(f64, 1.0), @floor(nearly_half + half));

    // Symmetric about zero, which is what "away from zero" means.
    var step: f64 = -4.0;
    while (step <= 4.0) : (step += 0.25) {
        try std.testing.expectEqual(-roundHalfAway(f64, step), roundHalfAway(f64, -step));
    }
}

// ---------------------------------------------------------------------------
// The pure math builtins
// ---------------------------------------------------------------------------

pub fn absolute(runtime: *Runtime, operand: Value) Error!Value {
    return switch (operand.view()) {
        .u8 => |held| Value.ofU8(held),
        .u16 => |held| Value.ofU16(held),
        .u32 => |held| Value.ofU32(held),
        .u64 => |held| Value.ofU64(held),
        .i8 => |held| if (held == std.math.minInt(i8))
            runtime.fail(.integer_overflow)
        else
            Value.ofI8(@intCast(@abs(held))),
        .i16 => |held| if (held == std.math.minInt(i16))
            runtime.fail(.integer_overflow)
        else
            Value.ofI16(@intCast(@abs(held))),
        .i32 => |held| if (held == std.math.minInt(i32))
            runtime.fail(.integer_overflow)
        else
            Value.ofI32(@intCast(@abs(held))),
        .i64 => |held| if (held == std.math.minInt(i64))
            runtime.fail(.integer_overflow)
        else
            Value.ofI64(@intCast(@abs(held))),
        .f16 => |held| Value.ofF16(@abs(held)),
        .f32 => |held| Value.ofF32(@abs(held)),
        .f64 => |held| Value.ofF64(@abs(held)),
        else => unreachable,
    };
}

/// `min` when `wants_minimum`, `max` otherwise — one body, because the
/// two differ by a single comparison.
pub fn extremum(wants_minimum: bool, left: Value, right: Value) Value {
    return switch (left.view()) {
        .u8 => |held| boxInteger(u8, pick(wants_minimum, held, right.asU8())),
        .u16 => |held| boxInteger(u16, pick(wants_minimum, held, right.asU16())),
        .u32 => |held| boxInteger(u32, pick(wants_minimum, held, right.asU32())),
        .u64 => |held| boxInteger(u64, pick(wants_minimum, held, right.asU64())),
        .i8 => |held| boxInteger(i8, pick(wants_minimum, held, right.asI8())),
        .i16 => |held| boxInteger(i16, pick(wants_minimum, held, right.asI16())),
        .i32 => |held| boxInteger(i32, pick(wants_minimum, held, right.asI32())),
        .i64 => |held| boxInteger(i64, pick(wants_minimum, held, right.asI64())),
        .f16 => |held| boxFloating(f16, pick(wants_minimum, held, right.asF16())),
        .f32 => |held| boxFloating(f32, pick(wants_minimum, held, right.asF32())),
        .f64 => |held| boxFloating(f64, pick(wants_minimum, held, right.asF64())),
        else => unreachable,
    };
}

/// The one statement of what `min` and `max` answer.  The float
/// semantic is written out rather than inherited from `@min`/`@max`,
/// because Zig's builtins lower to `llvm.minnum`/`llvm.maxnum`, whose
/// signed-zero ordering is target-dependent — relying on them made the
/// zero-tie rule a property of the host's instruction set instead of
/// the language.  The rule: a NaN loses to any number, an ordered pair
/// answers by comparison, and a tie orders the signs (`-0.0` below
/// `+0.0`), so `min` is negative when either operand is and `max` only
/// when both are.  `emitExtremum` in `codegen/lower.zig` lowers to
/// exactly this; the spec "min and max reductions over an array agree,
/// signed zeros and all" holds the two to it.
fn pick(wants_minimum: bool, left: anytype, right: @TypeOf(left)) @TypeOf(left) {
    const T = @TypeOf(left);
    if (@typeInfo(T) == .int) return if (wants_minimum) @min(left, right) else @max(left, right);
    if (std.math.isNan(left)) return right;
    if (std.math.isNan(right)) return left;
    if (left == right) {
        // Only zeros of opposite sign meet here as different values,
        // but the sign arithmetic answers correctly for every equal
        // pair, so nothing checks for zero by name.
        const negative = if (wants_minimum)
            std.math.signbit(left) or std.math.signbit(right)
        else
            std.math.signbit(left) and std.math.signbit(right);
        return if (negative) -@abs(left) else @abs(left);
    }
    if (wants_minimum) return if (left < right) left else right;
    return if (left > right) left else right;
}

test "float extrema choose the canonical signed zero" {
    const zeros = [_]f64{ 0.0, -0.0 };
    for (zeros) |left| {
        for (zeros) |right| {
            const smallest = extremum(true, Value.ofF64(left), Value.ofF64(right)).asF64();
            try std.testing.expectEqual(std.math.signbit(left) or std.math.signbit(right), std.math.signbit(smallest));

            const largest = extremum(false, Value.ofF64(left), Value.ofF64(right)).asF64();
            try std.testing.expectEqual(std.math.signbit(left) and std.math.signbit(right), std.math.signbit(largest));
        }
    }
}

test "float extrema keep the number when one operand is NaN" {
    const nan = std.math.nan(f64);
    try std.testing.expectEqual(@as(f64, 1.5), extremum(true, Value.ofF64(nan), Value.ofF64(1.5)).asF64());
    try std.testing.expectEqual(@as(f64, 1.5), extremum(false, Value.ofF64(1.5), Value.ofF64(nan)).asF64());
    try std.testing.expect(std.math.isNan(extremum(true, Value.ofF64(nan), Value.ofF64(nan)).asF64()));
    try std.testing.expect(std.math.isNan(extremum(false, Value.ofF64(nan), Value.ofF64(nan)).asF64()));
}

/// `min(max(middle, low), high)`, in that order — the order decides the
/// answer when the bounds cross — composed from `pick` so a NaN bound
/// or a signed-zero bound clamps the same way `min` and `max` answer.
pub fn clamp(held: Value, low: Value, high: Value) Value {
    return switch (held.view()) {
        .u8 => |middle| Value.ofU8(pick(true, pick(false, middle, low.asU8()), high.asU8())),
        .u16 => |middle| Value.ofU16(pick(true, pick(false, middle, low.asU16()), high.asU16())),
        .u32 => |middle| Value.ofU32(pick(true, pick(false, middle, low.asU32()), high.asU32())),
        .u64 => |middle| Value.ofU64(pick(true, pick(false, middle, low.asU64()), high.asU64())),
        .i8 => |middle| Value.ofI8(pick(true, pick(false, middle, low.asI8()), high.asI8())),
        .i16 => |middle| Value.ofI16(pick(true, pick(false, middle, low.asI16()), high.asI16())),
        .i32 => |middle| Value.ofI32(pick(true, pick(false, middle, low.asI32()), high.asI32())),
        .i64 => |middle| Value.ofI64(pick(true, pick(false, middle, low.asI64()), high.asI64())),
        .f16 => |middle| Value.ofF16(pick(true, pick(false, middle, low.asF16()), high.asF16())),
        .f32 => |middle| Value.ofF32(pick(true, pick(false, middle, low.asF32()), high.asF32())),
        .f64 => |middle| Value.ofF64(pick(true, pick(false, middle, low.asF64()), high.asF64())),
        else => unreachable,
    };
}

/// The float-only builtins, each answering **its operand's own
/// width**: `sqrt` of a `float` is a `float`, because a `double`
/// answer would be a narrowing waiting to happen at the next store
/// (docs/TYPES.md §9).
pub fn squareRoot(operand: Value) Value {
    return atOwnWidth(.square_root, operand);
}

pub fn floor(operand: Value) Value {
    return atOwnWidth(.floor, operand);
}

pub fn ceil(operand: Value) Value {
    return atOwnWidth(.ceil, operand);
}

/// `trunc(x)` — toward zero.  The fourth rounding, added when `long(x)`
/// stopped being the way to spell it (docs/NUMERICS.md §7).
pub fn truncate(operand: Value) Value {
    return atOwnWidth(.truncate, operand);
}

const Rounding = enum { square_root, floor, ceil, truncate };

fn atOwnWidth(comptime which: Rounding, operand: Value) Value {
    return switch (operand.tag) {
        .f16 => Value.ofF16(applied(which, f16, operand.asF16())),
        .f32 => Value.ofF32(applied(which, f32, operand.asF32())),
        else => Value.ofF64(applied(which, f64, operand.asF64())),
    };
}

fn applied(comptime which: Rounding, comptime T: type, held: T) T {
    return switch (which) {
        .square_root => @sqrt(held),
        .floor => @floor(held),
        .ceil => @ceil(held),
        .truncate => @trunc(held),
    };
}
