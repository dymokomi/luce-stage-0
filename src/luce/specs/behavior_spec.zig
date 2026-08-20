//! Behavioral correctness suite for the Luce language.
//!
//! Zig's test/behavior proves the language does what it says feature
//! by feature; this is our analog.  Each test is a `func main()` whose
//! `assert(...)`s trap on any wrong answer, so a green run means the
//! stated behavior holds — and stays holding, which is the point:
//! this is the regression net under every future compiler change.
//! Organized by feature area, not by anecdote.  Compile errors live
//! in errors_spec.zig; ARC behavior lives with the feature it protects.
//!
//! Every program here runs **twice**: interpreted and compiled, with
//! the printed bytes, the trap code and message, the call trace and
//! the leak census compared (`specs/agree.zig`).  A failure is either
//! a wrong answer or a disagreement between the engines, and both are
//! findings.

const std = @import("std");
const agree = @import("agree.zig");
const luce = @import("luce");
const mir = luce.mir;

const testing = std.testing;

/// The depth this suite has always run at.  A handful of the
/// recursive cases go past the 256 both engines default to.
const budget: agree.Provided = .{ .call_depth = 4096 };

/// The program runs on both engines, they agree, every `assert`
/// inside holds, and nothing is left alive — ARC releases every
/// reference, so a nonzero census is a bug in whichever engine
/// reported it.
fn agreeOk(source: []const u8) !void {
    return agree.okGiven(source, budget);
}

/// The mirror image: both engines abort the run with exactly `code`,
/// at the same place, with the same words.  Operands are deliberately
/// held in mutable locals — a compile-time-constant fault would be
/// caught by the analyzer instead and never reach an engine.
fn agreeTrap(source: []const u8, code: mir.TrapCode) !void {
    return agree.trapGiven(source, budget, code);
}

// ---------------------------------------------------------------------------
// Integer arithmetic
// ---------------------------------------------------------------------------

test "integers: the four operations and precedence" {
    try agreeOk(
        \\func main():
        \\    assert(2 + 3 == 5)
        \\    assert(10 - 4 == 6)
        \\    assert(6 * 7 == 42)
        \\    assert(20 // 3 == 6)
        \\    assert(2 + 3 * 4 == 14)
        \\    assert((2 + 3) * 4 == 20)
        \\    assert(-5 + 2 == -3)
        \\    assert(- -5 == 5)
        \\
    );
}

// ---------------------------------------------------------------------------
// The bit set (docs/BITWISE.md)
// ---------------------------------------------------------------------------
//
// Go's precedence, concrete-width two's-complement bit operations,
// checked left shifts, range-checked counts, and the literal spellings.
// Every row runs on both engines.

test "references: sharing, aliasing, and reassignment leave nothing alive" {
    // Every path the ARC emission counts (docs/MEMORY.md): a fresh
    // container transferred into a binding, an alias that retains, a `var`
    // reassigned to another reference, and a shared mutation each engine
    // must agree on — and the run must end with a zero census, which is
    // what proves the references were released rather than leaked.
    try agreeOk(
        \\func main():
        \\    let a = [1, 2, 3]
        \\    let b = a
        \\    b.append(4)
        \\    assert(len(a) == 4 and len(b) == 4)
        \\    var x = [1]
        \\    var y = [2, 3]
        \\    x = y
        \\    assert(len(x) == 2)
        \\    x.append(9)
        \\    assert(len(y) == 3)
        \\    var z = [0]
        \\    z = x
        \\    assert(len(z) == 3 and len(y) == 3)
        \\
    );
}

test "references: a struct and a union carry, share, and release their fields" {
    // A value aggregate's reference fields are counted through its copies
    // (docs/MEMORY.md): the struct returned below outlives the local its
    // list came from, two copies share one list, and the union's payload
    // list is freed with the last binding — the run ends with a zero
    // census, which is what proves the fields were released.
    try agreeOk(
        \\struct Box:
        \\    items: list[i64]
        \\
        \\union Node:
        \\    leaf(value: i64)
        \\    branch(kids: list[i64])
        \\
        \\func make() -> Box:
        \\    let xs = [1, 2, 3]
        \\    return Box(items = xs)
        \\
        \\func main():
        \\    let b = make()
        \\    b.items.append(4)
        \\    let c = b
        \\    c.items.append(5)
        \\    assert(len(b.items) == 5 and len(c.items) == 5)
        \\    let n = Node.branch(kids = [7, 8])
        \\    let m = n
        \\    match m:
        \\        leaf(value):
        \\            assert(false)
        \\        branch(kids):
        \\            assert(len(kids) == 2)
        \\
    );
}

test "the bit set: & | ^ ~ on default i64 values, in hex and binary spellings" {
    try agreeOk(
        \\func main():
        \\    assert(0xF0 & 0x3C == 0x30)
        \\    assert(0xF0 | 0x0F == 0xFF)
        \\    assert(0b1100 ^ 0b1010 == 0b0110)
        \\    assert(~0 == -1)
        \\    assert(~5 == -6)
        \\    assert(~(-1) == 0)
        \\    let wide: i64 = 0xFFFF_FFFF
        \\    assert(wide & 0xFF == 0xFF)
        \\    assert(wide + 0 == 4_294_967_295)
        \\    # Negative operands operate on the representation.
        \\    assert(-1 & 0xFF == 0xFF)
        \\    assert(-2 | 1 == -1)
        \\    assert(-1 ^ -1 == 0)
        \\
    );
}

test "the bit set: shifts transport bits at the operand's explicit width" {
    try agreeOk(
        \\func main():
        \\    assert(1 << 4 == 16)
        \\    assert(255 >> 4 == 15)
        \\    assert(1 << 0 == 1)
        \\    # `>>` is arithmetic: the operands are signed (D3).
        \\    assert(-8 >> 1 == -4)
        \\    assert(-1 >> 5 == -1)
        \\    # Left shift is checked arithmetic; legal shifts preserve
        \\    # the source width and unsigned right shift zero-fills.
        \\    var byte: u8 = 1
        \\    assert(byte << 7 == 128)
        \\    assert(u8(240) >> 4 == 15)
        \\    var wide: i64 = 1
        \\    assert(wide << 62 == 4611686018427387904)
        \\
    );
}

test "the bit set: left-shift overflow traps at the operand's explicit width" {
    try agree.trap(
        \\func main():
        \\    var value: u8 = 128
        \\    let shifted = value << 1
        \\
    , .integer_overflow);
    try agree.trap(
        \\func main():
        \\    var value: i64 = 1
        \\    let shifted = value << 63
        \\
    , .integer_overflow);
}

test "the bit set: Go's precedence means flags read as written" {
    try agreeOk(
        \\func main():
        \\    let flags = 0b1010
        \\    let mask = 0b0010
        \\    # `&` binds with `*`, so this is (flags & mask) != 0 —
        \\    # the parse C famously gets wrong (R1).
        \\    assert(flags & mask != 0)
        \\    # `|` and `^` bind with `+`.
        \\    assert(1 | 2 * 4 == 9)
        \\    assert(4 ^ 1 + 2 == 7)
        \\    assert(1 << 3 + 1 == 9)
        \\    assert((1 << 3) + 1 == 9)
        \\    assert(1 + (1 << 3) == 9)
        \\
    );
}

test "the bit set: compound forms write back like every other operator" {
    try agreeOk(
        \\func main():
        \\    var bits = 0b1111
        \\    bits &= 0b1010
        \\    assert(bits == 0b1010)
        \\    bits |= 0b0101
        \\    assert(bits == 0b1111)
        \\    bits ^= 0b0110
        \\    assert(bits == 0b1001)
        \\    bits <<= 2
        \\    assert(bits == 0b100100)
        \\    bits >>= 4
        \\    assert(bits == 0b10)
        \\
    );
}

test "the bit set: every integer width computes in place" {
    try agreeOk(
        \\func main():
        \\    var cells = array[u8](2)
        \\    cells[0] = 0xF0
        \\    cells[1] = 0x0F
        \\    assert(cells[0] | cells[1] == 0xFF)
        \\    assert(cells[0] >> 4 == 0xF)
        \\    assert(~cells[1] == 0xF0)
        \\
    );
}

test "the bit set: a shift count out of range traps, at either width and either sign" {
    // Held in vars so the folder cannot see them — the runtime check
    // is what these prove, on both engines at the same instruction.
    try agree.trap(
        \\func main():
        \\    var x: u8 = 1
        \\    var count: u8 = 8
        \\    let y = x << count
        \\
    , .shift_out_of_range);
    try agree.trap(
        \\func main():
        \\    var x: i64 = 1
        \\    var count: i64 = 64
        \\    let y = x << count
        \\
    , .shift_out_of_range);
    try agree.trap(
        \\func main():
        \\    var x = 8
        \\    var count = -1
        \\    let y = x >> count
        \\
    , .shift_out_of_range);
    try agree.trap(
        \\func main():
        \\    var x: i64 = 8
        \\    var count: i64 = -3
        \\    let y = x >> count
        \\
    , .shift_out_of_range);
}

// `str(x)` is the text conversion for scalar values (docs/NUMERICS.md).
// A builder is a mutable reference object rather than a scalar, so it
// takes an explicit snapshot with `b.build()`.

test "str(x) prints every scalar, and builder.build() takes a snapshot" {
    try agreeOk(
        \\func main():
        \\    assert(str(42) == "42")
        \\    assert(str(-7) == "-7")
        \\    assert(str(2.5) == "2.5")
        \\    assert(str(3.0) == "3")
        \\    assert(str(true) == "true")
        \\    assert(str(false) == "false")
        \\    assert(str("already") == "already")
        \\    var b = builder()
        \\    b.append("he")
        \\    b.append("llo")
        \\    assert(b.build() == "hello")
        \\    # `build` takes a snapshot; the builder is still usable.
        \\    b.append("!")
        \\    assert(b.build() == "hello!")
        \\    assert(len(b) == 6)
        \\
    );
}

// `{x:.2f}` — format specs inside f-strings, and nowhere else,
// because that is where formatting happens (docs/NUMERICS.md §8).
// One form: `.Nf` on a numeric value. It lowers to `strings.format_float`,
// which already existed and already rounds half away from zero, so
// this is one production in the f-string scanner and no runtime.

test "f-strings: a :.Nf spec writes an f64 to N decimal places" {
    try agree.printsGiven(
        \\import std.strings
        \\
        \\func main():
        \\    let mean = 23.998425
        \\    print(f"mean = {mean:.2f}")
        \\    let rate = 1.0 / 3.0
        \\    print(f"{3} rolls, {rate:.3f}/s")
        \\    # Display rounding is halfway away from zero.
        \\    print(f"{2.5:.0f} {-2.5:.0f}")
        \\    # Integer holes use the same explicit formatting request.
        \\    print(f"{7:.2f}")
        \\    # And a hole with no spec is unchanged.
        \\    print(f"{mean}")
        \\
    , budget, "mean = 24.00\n3 rolls, 0.333/s\n3 -3\n7.00\n23.998425\n");
}

test "f-strings: a colon inside brackets belongs to the brackets" {
    try agree.printsGiven(
        \\import std.strings
        \\
        \\func main():
        \\    let parts = ["a", "b", "c"]
        \\    let sliced = parts[0:2]
        \\    print(f"{len(sliced)} {parts[1]} {len(parts[0:3])}")
        \\    let text = "hello"
        \\    print(f"{text[1:3]}")
        \\
    , budget, "2 b 3\nel\n");
}

test "str is the text type and conversion" {
    try agreeOk(
        \\func main():
        \\    let answer: str = str(21)
        \\    assert(answer == "21")
        \\
    );
}

test "str(x) folds in a constant, in the same bytes a run would print" {
    try agreeOk(
        \\const count = str(42)
        \\const ratio = str(2.5)
        \\const flag = str(true)
        \\const same = str("x")
        \\const joined = count + " " + ratio + " " + flag + " " + same
        \\
        \\func main():
        \\    assert(joined == "42 2.5 true x")
        \\    assert(str(42) == count)
        \\    assert(str(2.5) == ratio)
        \\
    );
}

test "integer conversion truncates toward zero" {
    try agreeOk(
        \\func main():
        \\    assert(i64(2.5) == 2)
        \\    assert(i64(-2.5) == -2)
        \\    assert(i64(0.5) == 0)
        \\    assert(i64(-0.5) == 0)
        \\    assert(i64(2.4) == 2)
        \\    assert(i64(-2.4) == -2)
        \\    assert(i64(2.6) == 2)
        \\    assert(i64(-2.6) == -2)
        \\    assert(i64(3.9) == 3)
        \\    assert(i64(-3.9) == -3)
        \\    assert(i64(7) == 7)
        \\    # Toward zero has a spelling of its own again.
        \\    assert(trunc(2.9) == 2.0)
        \\    assert(trunc(-2.9) == -2.0)
        \\    assert(i64(trunc(-2.9)) == -2)
        \\    # Explicit integer conversion is the same toward-zero
        \\    # direction as trunc, but returns an integer.
        \\    assert(floor(-2.5) == -3.0)
        \\    assert(ceil(-2.5) == -2.0)
        \\    assert(trunc(-2.5) == -2.0)
        \\    assert(i64(-2.5) == -2)
        \\
    );
}

test "integer conversion and math.round remain deliberately distinct" {
    try agreeOk(
        \\import std.math
        \\
        \\func main():
        \\    var nearly: f64 = 0.49999999999999994
        \\    assert(i64(nearly) == 0)
        \\    assert(math.round(nearly) == 0.0)
        \\    assert(floor(nearly + 0.5) == 1.0)
        \\    assert(i64(2.5) == 2)
        \\    assert(math.round(2.5) == 3.0)
        \\    assert(i64(-2.5) == -2)
        \\    assert(math.round(-2.5) == -3.0)
        \\    for step in range(-40, 41):
        \\        let x = f64(step) / 4.0
        \\        assert(f64(i64(x)) == trunc(x))
        \\
    );
}

test "a trapping left conversion runs before the right operand" {
    var session = try agree.compare(
        \\func right() -> i8:
        \\    print("right")
        \\    return 1
        \\
        \\func main():
        \\    var wide: f64 = 128.0
        \\    let bad = i8(wide) + right()
        \\
    , budget);
    defer session.deinit();

    try testing.expectEqual(mir.TrapCode.conversion_range, session.end.trapped);
    try testing.expectEqualStrings("", session.printed());
}

test "trap: i64(x) refuses NaN, the infinities, and out of range" {
    try agreeTrap(
        \\func main():
        \\    var big = 1.0
        \\    while big < 1.0e30:
        \\        big = big * 10.0
        \\    let bad = i64(big)
        \\
    , .conversion_range);
    try agreeTrap(
        \\func main():
        \\    var zero = 0.0
        \\    let bad = i64(zero / zero)
        \\
    , .conversion_range);
    try agreeTrap(
        \\func main():
        \\    var zero = 0.0
        \\    var one = 1.0
        \\    let bad = i64(one / zero)
        \\
    , .conversion_range);
}

// `/` is **real division** and answers f64 for integer operands
// (docs/NUMERICS.md §2, §4): the classic `1/2 == 0` is the single
// most common cause of surprise for people who do not already think
// in machine words, and the quotient that answers `0` is `1 // 2`.

test "integers: / is real division and answers f64" {
    try agreeOk(
        \\func main():
        \\    assert(1 / 2 == 0.5)
        \\    assert(7 / 2 == 3.5)
        \\    assert(-7 / 2 == -3.5)
        \\    assert(6 / 3 == 2.0)
        \\    let total = 10
        \\    let count = 4
        \\    assert(total / count == 2.5)
        \\
    );
}

test "integers: / never traps, and 1 / 0 is inf" {
    // `//` and `%` keep integer semantics, including traps; `/` first
    // converts integer operands to f64 and follows IEEE arithmetic
    // (docs/NUMERICS.md §4).
    try agreeOk(
        \\func main():
        \\    var zero = 0
        \\    var one = 1
        \\    let infinity = one / zero
        \\    assert(infinity > 9.0e300)
        \\    let negative = (0 - one) / zero
        \\    assert(negative < -9.0e300)
        \\    let nan = zero / zero
        \\    assert(nan != nan)
        \\    # And `minInt / -1`, which the i64 quotient could not hold.
        \\    var low: i64 = -9223372036854775808
        \\    var minus_one = -1
        \\    assert(low / minus_one > 9.0e18)
        \\
    );
}

test "integers: // and % keep the trap / gave up" {
    try agreeTrap(
        \\func main():
        \\    var zero = 0
        \\    let bad = 1 // zero
        \\
    , .divide_by_zero);
    try agreeTrap(
        \\func main():
        \\    var zero = 0
        \\    let bad = 1 % zero
        \\
    , .divide_by_zero);
    try agreeTrap(
        \\func main():
        \\    var low: i64 = -9223372036854775808
        \\    var minus_one = -1
        \\    let bad = low // minus_one
        \\
    , .integer_overflow);
    // The same overflow at the other arithmetic width: `minInt // -1`
    // is one value past the top at 32 bits exactly as it is at 64
    // (docs/TYPES.md §4), and the check is per-width or it is wrong.
    try agreeTrap(
        \\func main():
        \\    var low: i32 = -2147483648
        \\    var minus_one: i32 = -1
        \\    let bad = low // minus_one
        \\
    , .integer_overflow);
}

// `//` and `%` are the integer pair and they **floor** together
// (docs/NUMERICS.md §3).  This is the memo's table verbatim, on both
// engines, plus the identity the pairing is chosen to keep.

test "integers: // and % floor together, and the identity holds" {
    try agreeOk(
        \\func main():
        \\    assert(7 // 3 == 2)
        \\    assert(7 % 3 == 1)
        \\    assert(-7 // 3 == -3)
        \\    assert(-7 % 3 == 2)
        \\    assert(7 // -3 == -3)
        \\    assert(7 % -3 == -2)
        \\    assert(-7 // -3 == 2)
        \\    assert(-7 % -3 == -1)
        \\    assert(0 % 5 == 0)
        \\    assert(6 % 3 == 0)
        \\    assert(-6 % 3 == 0)
        \\    assert(20 // 3 == 6)
        \\
    );
}

test "integers: b * (a // b) + (a % b) == a, over every sign" {
    try agreeOk(
        \\func main():
        \\    for a in range(-9, 10):
        \\        for b in range(-4, 5):
        \\            if b != 0:
        \\                assert(b * (a // b) + (a % b) == a)
        \\                # `%` takes the sign of the divisor, so a
        \\                # positive divisor never yields a negative.
        \\                if b > 0:
        \\                    assert(a % b >= 0)
        \\                    assert(a % b < b)
        \\                else:
        \\                    assert(a % b <= 0)
        \\                    assert(a % b > b)
        \\
    );
}

test "integers: floor-mod by a power of two is a mask, negatives included" {
    // What C's remainder cannot do without a sign fixup, and the
    // reason `bf.luc`'s byte decrement is `(x - 1) % 256` now.
    try agreeOk(
        \\func main():
        \\    for x in range(-600, 600):
        \\        let wrapped = x % 256
        \\        assert(wrapped >= 0)
        \\        assert(wrapped < 256)
        \\    assert(-1 % 256 == 255)
        \\    assert(0 % 256 == 0)
        \\    assert(256 % 256 == 0)
        \\
    );
}

test "integers: // and %= and //= carry the same rule" {
    try agreeOk(
        \\func main():
        \\    var n = -7
        \\    n //= 3
        \\    assert(n == -3)
        \\    var m = -7
        \\    m %= 3
        \\    assert(m == 2)
        \\
    );
}

test "floats: % floors with the integer operator, and // is its floor" {
    // Integer and floating operands require explicit types, but the
    // operator rule is still uniform across the two numeric families.
    try agreeOk(
        \\func main():
        \\    assert(7.0 % 3.0 == 1.0)
        \\    assert(-7.0 % 3.0 == 2.0)
        \\    assert(7.0 % -3.0 == -2.0)
        \\    assert(-7.0 % -3.0 == -1.0)
        \\    assert(7.0 // 3.0 == 2.0)
        \\    assert(-7.0 // 3.0 == -3.0)
        \\    assert(7.0 // -3.0 == -3.0)
        \\    assert(-7.0 // -3.0 == 2.0)
        \\    assert(-5.5 % 2.0 == 0.5)
        \\
    );
}

test "integers: the i64 range is honored" {
    try agreeOk(
        \\func main():
        \\    let high: i64 = 9223372036854775807
        \\    assert(high > 0)
        \\    assert(high - 1 == 9223372036854775806)
        \\    let low = 0 - high
        \\    assert(low - 1 < low)
        \\
    );
}

test "integers: the i32 range is honored at its own end" {
    // The same program one rung down the ladder.  A literal has no
    // type until it lands (docs/TYPES.md §1), so the only difference
    // between this test and the one above is the word in the
    // annotation — which is the whole claim the two of them make
    // together.
    try agreeOk(
        \\func main():
        \\    let high: i32 = 2147483647
        \\    assert(high > 0)
        \\    assert(high - 1 == 2147483646)
        \\    let low = 0 - high
        \\    assert(low - 1 < low)
        \\
    );
}

test "integers: i64 minimum is written the way it reads" {
    // `-9223372036854775808` is a minus and a literal whose magnitude
    // is one past the largest positive i64. Range-checking the
    // magnitude on its own makes the smallest i64 the one number
    // nobody can spell, so the sign folds into the literal first.
    try agreeOk(
        \\func main():
        \\    let low: i64 = -9223372036854775808
        \\    assert(low < 0)
        \\    assert(low + 1 == -9223372036854775807)
        \\    assert(low == 0 - 9223372036854775807 - 1)
        \\    let step: i64 = -9223372036854775808 // 2
        \\    assert(step == -4611686018427387904)
        \\
    );
}

test "integers: i32 minimum is written the way it reads too" {
    // The sign folds into the literal before the range check at every
    // width, not only at the one the check used to be written for.
    try agreeOk(
        \\func main():
        \\    let low: i32 = -2147483648
        \\    assert(low < 0)
        \\    assert(low + 1 == -2147483647)
        \\    assert(low == 0 - 2147483647 - 1)
        \\    let step: i32 = -2147483648 // 2
        \\    assert(step == -1073741824)
        \\
    );
}

test "integers: i64 minimum folds in a file-scope constant too" {
    try agreeOk(
        \\const low: i64 = -9223372036854775808
        \\const high: i64 = 9223372036854775807
        \\
        \\func main():
        \\    assert(low < high)
        \\    assert(low + high == -1)
        \\
    );
}

test "a minus does not move where a literal lands" {
    // `lowerUnary` hands the requested type through a negate. The literal
    // is parsed at that exact width before the sign is applied.
    //
    //   * binary64's `-0.1` differs from binary32's nearest value.
    //   * `-3000000000` is checked directly against i64's range.
    try agreeOk(
        \\func main():
        \\    let small: f64 = -0.1
        \\    let plain: f64 = 0.1
        \\    assert(small == 0.0 - plain)
        \\    let narrow: f32 = -0.1
        \\    assert(f64(narrow) != small)
        \\    let wide: i64 = -3000000000
        \\    assert(wide + 3000000000 == 0)
        \\    assert(wide < -2147483648)
        \\
    );
}

// ---------------------------------------------------------------------------
// arithmetic on floats and doubles
// ---------------------------------------------------------------------------

test "floats: arithmetic, IEEE division, and builtins" {
    // Unannotated, so these are `f32`s — every value here is exact
    // in binary32 and the answers do not depend on the width, which
    // is why this is the test that runs at the default one.
    try agreeOk(
        \\func main():
        \\    assert(1.5 + 2.5 == 4.0)
        \\    assert(3.0 * 2.0 == 6.0)
        \\    assert(1.0 / 4.0 == 0.25)
        \\    assert(sqrt(9.0) == 3.0)
        \\    assert(floor(2.7) == 2.0)
        \\    assert(ceil(2.1) == 3.0)
        \\    assert(abs(-2.5) == 2.5)
        \\    assert(1.0 / 0.0 > 3.0e38)
        \\
    );
}

test "doubles: the same arithmetic, and an overflow bound only binary64 can state" {
    // The twin of the test above at the wide rung.  `9.0e300` is not
    // a finite `f32`, so the bound the old spec wrote is now a
    // statement a `f64` place has to hold — which is exactly what
    // makes it worth writing down separately.
    try agreeOk(
        \\func main():
        \\    let sum: f64 = 1.5 + 2.5
        \\    assert(sum == 4.0)
        \\    let quarter: f64 = 1.0 / 4.0
        \\    assert(quarter == 0.25)
        \\    let nine: f64 = 9.0
        \\    assert(sqrt(nine) == 3.0)
        \\    let infinity: f64 = 1.0 / 0.0
        \\    assert(infinity > 9.0e300)
        \\    assert(0.0 - infinity < -9.0e300)
        \\
    );
}

// ---------------------------------------------------------------------------
// Numbers that mix (docs/NUMERICS.md)
// ---------------------------------------------------------------------------

test "the conversions are still spelled where a program spells them" {
    try agreeOk(
        \\func main():
        \\    let n = 7
        \\    let x = 2.0
        \\    assert(f64(n) / x == 3.5)
        \\    assert(i64(x) + n == 9)
        \\    assert(f64(i64(3.9)) == 3.0)
        \\
    );
}

test "explicit conversion composes integer and float arithmetic" {
    try agreeOk(
        \\func main():
        \\    let n = 7
        \\    let x = 2.0
        \\    assert(f64(n) + x == 9.0)
        \\    assert(x + f64(n) == 9.0)
        \\    assert(f64(n) - x == 5.0)
        \\    assert(x - f64(n) == -5.0)
        \\    assert(f64(n) * x == 14.0)
        \\    assert(x * f64(n) == 14.0)
        \\    assert(f64(n) / x == 3.5)
        \\    assert(x / f64(n) == 0.2857142857142857)
        \\    assert(f64(n) % x == 1.0)
        \\    assert(x % f64(n) == 2.0)
        \\
    );
}

test "an explicitly converted operator answers an f64, printed as one" {
    // `str` of a whole f64 is its shortest round-trip, so "8" and
    // not "8.0" — the division below is what shows the type moved.
    try agree.printsGiven(
        \\func main():
        \\    let n = 7
        \\    print(str(f64(n) + 1.0))
        \\    print(str(f64(1) + 0.5))
        \\    print(str(f64(n) / 2.0))
        \\    var f = 2.0
        \\    f += 1
        \\    f *= 2
        \\    print(str(f / 8.0))
        \\
    , budget, "8\n1.5\n3.5\n0.75\n");
}

test "contextual literals reach annotations, arguments, returns, and fields" {
    try agreeOk(
        \\struct Point:
        \\    x: f64
        \\    y: f64
        \\
        \\func scale(by: f64) -> f64:
        \\    return by * 2
        \\
        \\func whole() -> f64:
        \\    return 3
        \\
        \\func maybe_whole(present: bool) -> f64?:
        \\    if present:
        \\        return 4
        \\    return none
        \\
        \\func main():
        \\    let f: f64 = 1
        \\    assert(f == 1.0)
        \\    assert(scale(3) == 6.0)
        \\    assert(whole() == 3.0)
        \\    let p = Point(x = 1, y = 2.5)
        \\    assert(p.x == 1.0)
        \\    # Presence narrowing exposes the contextually typed value.
        \\    let held = maybe_whole(true)
        \\    if held != none:
        \\        assert(held == 4.0)
        \\    assert(maybe_whole(false) == none)
        \\
    );
}

// The names the language answers to are lowercase (docs/TYPES.md D8):
// every numeric width, plus `bool`, `char`, `str`, `bytes`, and the
// container/resource constructors beside them. A
// TitleCase name is always a struct of the reader's own, which is what
// makes the case of a type name say who defined it.
//
// The TitleCase spellings do not resolve at all: a program that
// writes one is told the lowercase name it is written with now.
test "types: the language's own names are lowercase" {
    try agreeOk(
        \\struct Point:
        \\    x: f64
        \\    y: f64
        \\
        \\func total(xs: list[i64]) -> i64:
        \\    var sum: i64 = 0
        \\    for x in xs:
        \\        sum += x
        \\    return sum
        \\
        \\func main():
        \\    let n: i64 = 7
        \\    let r: f64 = 2.5
        \\    let s: str = "hi"
        \\    let b: bool = true
        \\    var xs = list[i64]()
        \\    xs.append(n)
        \\    xs.append(3)
        \\    var grid = array[f64](2, 2)
        \\    grid[0, 0] = 1.5
        \\    var counts = map[str, i64]()
        \\    counts["a"] = 1
        \\    var text = builder()
        \\    text.append(s)
        \\    let p = Point(x = 1, y = r)
        \\    assert(total(xs) == 10)
        \\    assert(i64(r) == 2)
        \\    assert(f64(n) == 7.0)
        \\    assert(str(grid[0, 0] + p.x) == "2.5")
        \\    assert(counts["a"] == 1)
        \\    assert(text.build() == "hi")
        \\    assert(b)
        \\
    );
}

// A numeric literal has no type of its own: it takes the type of the
// place it lands in, and its text is read at that exact type
// (docs/TYPES.md D3). This pins every major contextual place,
// including file-scope constants.
test "literals: a number lands on the type its context names" {
    try agreeOk(
        \\const whole: f64 = 7
        \\const negative: f64 = -3
        \\const folded: f64 = 2 * 3 + 1
        \\const plain = 7
        \\
        \\func takes(x: f64) -> f64:
        \\    return x
        \\
        \\func answers() -> f64:
        \\    return 12
        \\
        \\func main():
        \\    assert(whole == 7.0)
        \\    assert(negative == -3.0)
        \\    assert(folded == 7.0)
        \\    assert(plain == 7)
        \\    let local: f64 = 5
        \\    assert(local == 5.0)
        \\    let held: f64? = 6
        \\    assert(held == 6.0)
        \\    assert(takes(8) == 8.0)
        \\    assert(answers() == 12.0)
        \\
    );
}

test "container literals are contextual and numeric builtins stay exact" {
    try agreeOk(
        \\func main():
        \\    var xs: list[f64] = [1, 2, 3]
        \\    xs.append(4)
        \\    xs[0] = 9
        \\    assert(xs[0] == 9.0)
        \\    assert(xs[3] == 4.0)
        \\    assert(len(xs) == 4)
        \\    let plain = [1, 2, 3]
        \\    assert(plain[0] == 1)
        \\    let x = 7.5
        \\    assert(clamp(x, f64(0), f64(5)) == 5.0)
        \\    assert(min(x, f64(8)) == 7.5)
        \\    assert(max(f64(1), x) == 7.5)
        \\
    );
}

// An explicit integer-to-float conversion exposes its rounding. The
// boundary is 2^53, where binary64 stops representing consecutive
// integers (docs/NUMERICS.md §5).

test "explicit conversion at 2^53 makes the chosen rounding visible" {
    try agreeOk(
        \\func main():
        \\    var two53: i64 = 9007199254740992
        \\    var as_float: f64 = 9007199254740992.0
        \\    assert(f64(two53) == as_float)
        \\    # The next integer rounds to the same binary64 value.
        \\    assert(f64(two53 + 1) == as_float)
        \\    assert(i64(as_float) == two53)
        \\    assert(f64(two53 - 1) < as_float)
        \\
    );
}

// The row the ladder adds to that table (docs/TYPES.md §5).  2^24 is
// where a binary32 stops holding consecutive integers, and 16,777,216
// is a number ordinary programs reach — which is why `i32` against
// `f32` gets the same treatment 2^53 got, rather than an argument
// that it is unlikely.

test "explicit conversion at 2^24 exposes binary32 rounding" {
    try agreeOk(
        \\func main():
        \\    var two24: i32 = 16777216
        \\    var as_float: f32 = 16777216.0
        \\    assert(f32(two24) == as_float)
        \\    assert(f32(two24 + 1) == as_float)
        \\    assert(i32(as_float) == two24)
        \\    assert(f32(two24 - 1) < as_float)
        \\
    );
}

// A constructor gives its literal argument a type directly, so the
// literal is never parsed at an unrelated default width first.

test "a conversion constructor contextualizes its literal argument" {
    // `f64(0.1)` reads `0.1` directly as binary64. An explicitly nested
    // `f64(f32(0.1))` requests the different, twice-rounded value.
    try agreeOk(
        \\func main():
        \\    let annotated: f64 = 0.1
        \\    assert(f64(0.1) == annotated)
        \\    assert(f64(0.1) != f64(f32(0.1)))
        \\    assert(f64(f32(0.1)) != annotated)
        \\    # And the integer direction: the constructor's own type is
        \\    # the place, so a value past an `i32` is not refused for
        \\    # overflowing one nobody wrote.
        \\    assert(i64(3000000000) == 3000000000)
        \\
    );
}

test "the width-polymorphic builtins land their arguments too" {
    // `sqrt` answers its operand's float type (docs/TYPES.md §9), and
    // the surrounding place contextualizes a literal operand first.
    try agreeOk(
        \\func main():
        \\    let two: f64 = 2.0
        \\    let wide: f64 = sqrt(2.0)
        \\    assert(wide == sqrt(two))
        \\    let narrow: f32 = sqrt(2.0)
        \\    assert(wide != f64(narrow))
        \\    # abs, min, max and clamp keep the same rule.
        \\    let held: f64 = abs(-0.1)
        \\    assert(held == 0.1)
        \\    let picked: f64 = min(0.1, 1.0)
        \\    assert(picked == 0.1)
        \\    let bounded: f64 = clamp(0.1, 0.0, 1.0)
        \\    assert(bounded == 0.1)
        \\
    );
}

test "explicit integer-to-float comparison is exact where f64 can represent it" {
    // §5's first row, and the one place the lowering may skip the
    // intrinsic: every `i32` is exactly a `f64`, so `sitofp` and an
    // ordinary `fcmp` answer what comparing the numbers would.  The
    // spec pins the answers rather than the lowering, because the
    // answers are what may not move.
    try agreeOk(
        \\func main():
        \\    var high: i32 = 2147483647
        \\    var low: i32 = -2147483648
        \\    var high_double: f64 = 2147483647.0
        \\    var low_double: f64 = -2147483648.0
        \\    assert(f64(high) == high_double)
        \\    assert(not (f64(high) < high_double))
        \\    assert(not (f64(high) > high_double))
        \\    assert(f64(low) == low_double)
        \\    assert(f64(high) > high_double - 0.5)
        \\    assert(f64(high) < high_double + 0.5)
        \\    assert(f64(low) < low_double + 0.5)
        \\    assert(f64(low) > low_double - 0.5)
        \\
    );
}

test "explicit conversion orders integers with fractional floats" {
    try agreeOk(
        \\func main():
        \\    assert(f64(1) < 1.5)
        \\    assert(1.5 > f64(1))
        \\    assert(f64(2) > 1.5)
        \\    assert(1.5 < f64(2))
        \\    assert(f64(1) == 1.0)
        \\    assert(1.0 == f64(1))
        \\    assert(f64(1) != 1.5)
        \\    assert(f64(-1) > -1.5)
        \\    assert(f64(-2) < -1.5)
        \\    assert(f64(0) >= -0.0)
        \\    assert(f64(0) <= -0.0)
        \\
    );
}

test "explicit conversion compares an integer with infinity and NaN" {
    try agreeOk(
        \\func main():
        \\    var one: f64 = 1.0
        \\    var zero: f64 = 0.0
        \\    let infinity = one / zero
        \\    let nan = zero / zero
        \\    var big: i64 = 9223372036854775807
        \\    assert(f64(big) < infinity)
        \\    assert(infinity > f64(big))
        \\    assert(f64(0 - big - 1) > 0.0 - infinity)
        \\    # NaN is unordered with everything, so only != holds.
        \\    assert(f64(0) != nan)
        \\    assert(not (f64(0) == nan))
        \\    assert(not (f64(0) < nan))
        \\    assert(not (f64(0) > nan))
        \\    assert(not (f64(0) >= nan))
        \\    assert(not (f64(0) <= nan))
        \\
    );
}

test "explicit numeric conversion folds the same way in a constant" {
    try agreeOk(
        \\const two53: i64 = 9007199254740992
        \\const after53: i64 = 9007199254740993
        \\const as_f64: f64 = 9007199254740992.0
        \\const below = f64(two53) == as_f64
        \\const above = f64(after53) == as_f64
        \\const ordered = as_f64 < f64(after53 + 1)
        \\const converted = f64(1) + 2.5
        \\
        \\func main():
        \\    assert(below)
        \\    assert(above)
        \\    assert(ordered)
        \\    assert(converted == 3.5)
        \\
    );
}

// ---------------------------------------------------------------------------
// Compound assignment
// ---------------------------------------------------------------------------

test "compound assignment on names: every operator at i64 and f64" {
    try agreeOk(
        \\func main():
        \\    var n = 10
        \\    n += 5
        \\    assert(n == 15)
        \\    n -= 3
        \\    assert(n == 12)
        \\    n *= 2
        \\    assert(n == 24)
        \\    n //= 5
        \\    assert(n == 4)
        \\    n %= 3
        \\    assert(n == 1)
        \\    var f = 2.0
        \\    f += 0.5
        \\    f *= 4.0
        \\    f /= 2.5
        \\    assert(f == 4.0)
        \\
    );
}

test "compound assignment concatenates strings with +=" {
    try agreeOk(
        \\func main():
        \\    var s = "a"
        \\    s += "b"
        \\    s += "c" + "d"
        \\    assert(s == "abcd")
        \\
    );
}

test "compound assignment on struct fields and container elements" {
    try agreeOk(
        \\struct Counter:
        \\    value: i64
        \\
        \\func main():
        \\    var c = Counter(value = 1)
        \\    c.value += 9
        \\    c.value *= 2
        \\    assert(c.value == 20)
        \\    var xs = [1, 2, 3]
        \\    xs[1] += 10
        \\    assert(xs[1] == 12)
        \\    var grid = array[i64](2, 2)
        \\    grid[1, 1] += 7
        \\    grid[1, 1] -= 2
        \\    assert(grid[1, 1] == 5)
        \\    var m = map[str, i64]()
        \\    m["k"] = 5
        \\    m["k"] *= 4
        \\    assert(m["k"] == 20)
        \\
    );
}

test "a let binding freezes the name, never the object it reached" {
    // The rule everywhere else in the language: `xs.append(v)`,
    // `xs.sort()` and `xs[0] = v` all go through an immutable name,
    // because none of them writes the name.  A nested place is the
    // same store spelled with a field on the end — the rebuild stops
    // at the innermost `index_set` and the local is never re-stored —
    // so it obeys the same rule.  It did not until this spec was
    // written, and the sentence it was refused with named a
    // reassignment that the emitted code does not perform.
    //
    // A borrowed parameter is the case that matters: every function
    // that takes a container takes a `let`-bound name for it.
    try agreeOk(
        \\struct Cell:
        \\    value: i64
        \\    label: str
        \\
        \\struct Bag:
        \\    cells: list[Cell]
        \\
        \\func bump(cells: list[Cell]):
        \\    cells[0].value += 1
        \\
        \\func main():
        \\    let cells: list[Cell] = [Cell(value = 1, label = "a")]
        \\    cells[0].value = 10
        \\    cells[0].label = "b"
        \\    bump(cells)
        \\    assert(cells[0].value == 11)
        \\    assert(cells[0].label == "b")
        \\
        \\    # Down a field, into the object it names, and on to a
        \\    # field of the element.
        \\    let bag = Bag(cells = [Cell(value = 2, label = "x")])
        \\    bag.cells[0].value = 7
        \\    assert(bag.cells[0].value == 7)
        \\
        \\    # And the two spellings that were always legal, beside
        \\    # the one that now is.
        \\    let numbers = [1, 2, 3]
        \\    numbers[0] = 9
        \\    numbers.append(4)
        \\    assert(numbers[0] == 9 and len(numbers) == 4)
        \\
        \\    let grid = array[Cell](2)
        \\    grid[1].value = 5
        \\    assert(grid[1].value == 5)
        \\
    );
}

// ---------------------------------------------------------------------------
// Zero values: define on write, never on read
// ---------------------------------------------------------------------------

test "a compound store into a missing map key begins from the value type's zero" {
    // The ruling: `m[k] += 1` works because every type has a zero and
    // a compound store says on its left that it is writing.  Every
    // rung of the ladder, and `str` beside them, because the zero
    // is the *value* — not an identity element chosen per operator.
    try agreeOk(
        \\func main():
        \\    var ints = map[str, i32]()
        \\    ints["k"] += 1
        \\    assert(ints["k"] == 1)
        \\    var longs = map[str, i64]()
        \\    longs["k"] += 2
        \\    assert(longs["k"] == 2)
        \\    var floats = map[str, f32]()
        \\    floats["k"] += 0.5
        \\    assert(floats["k"] == 0.5)
        \\    var doubles = map[str, f64]()
        \\    doubles["k"] += 0.25
        \\    assert(doubles["k"] == 0.25)
        \\    var words = map[str, str]()
        \\    words["k"] += "text"
        \\    assert(words["k"] == "text")
        \\    var octets = map[str, u8]()
        \\    octets["k"] += 7
        \\    assert(octets["k"] == 7)
        \\    var shorts = map[str, i16]()
        \\    shorts["k"] += 300
        \\    assert(shorts["k"] == 300)
        \\    var halves = map[str, f16]()
        \\    halves["k"] += 1.5
        \\    assert(halves["k"] == 1.5)
        \\
    );
}

test "the zero a missing key begins from is the value, not an identity element" {
    // `m[k] *= 2` on a key that is not there is 0, because the entry
    // is defined at zero and *then* multiplied.  An identity element
    // per operator would make it 2, which would be a different rule
    // wearing the same syntax.
    try agreeOk(
        \\func main():
        \\    var m = map[str, i64]()
        \\    m["times"] *= 2
        \\    assert(m["times"] == 0)
        \\    m["minus"] -= 5
        \\    assert(m["minus"] == -5)
        \\    m["quotient"] //= 3
        \\    assert(m["quotient"] == 0)
        \\    m["remainder"] %= 3
        \\    assert(m["remainder"] == 0)
        \\    assert(len(m) == 4)
        \\
    );
}

test "a compound store defines exactly one entry and evaluates its key once" {
    try agreeOk(
        \\func main():
        \\    var calls: list[i64] = [0]
        \\    var m = map[str, i64]()
        \\    m[bump(calls)] += 5
        \\    assert(calls[0] == 1)
        \\    assert(len(m) == 1)
        \\    assert(m["k"] == 5)
        \\    m[bump(calls)] += 5
        \\    assert(calls[0] == 2)
        \\    assert(len(m) == 1)
        \\    assert(m["k"] == 10)
        \\
        \\func bump(counter: list[i64]) -> str:
        \\    counter[0] = counter[0] + 1
        \\    return "k"
        \\
    );
}

test "a defined str value is owned: it grows from empty and frees once" {
    // The entry inserted at "" is the map's, and the concatenation
    // that replaces it frees it.  Two hundred rounds past the
    // small-string bound is what makes a missed free a census entry
    // rather than a rounding error.
    try agreeOk(
        \\func main():
        \\    var m = map[str, str]()
        \\    var at = 0
        \\    while at < 200:
        \\        m["a-key-far-past-the-small-string-bound-so-it-allocates"] += "chunk-"
        \\        at = at + 1
        \\    assert(len(m["a-key-far-past-the-small-string-bound-so-it-allocates"]) == 1200)
        \\    assert(len(m) == 1)
        \\
    );
}

test "the counter idiom, and the map it leaves behind" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let text = "the cat sat on the mat the end"
        \\    var counts = map[str, i64]()
        \\    for word in text.split(" "):
        \\        counts[word] += 1
        \\    assert(counts["the"] == 3)
        \\    assert(counts["cat"] == 1)
        \\    assert(len(counts) == 6)
        \\
    );
}

test "a compound store through a nested place defines its leaf too" {
    // `s.counts[w] += 1` reaches the same place `counts[w] += 1`
    // does, so it has to mean the same thing.
    try agreeOk(
        \\struct Tally:
        \\    counts: map[str, i64]
        \\
        \\func main():
        \\    var t = Tally(counts = map[str, i64]())
        \\    t.counts["w"] += 1
        \\    t.counts["w"] += 1
        \\    assert(t.counts["w"] == 2)
        \\    assert(len(t.counts) == 1)
        \\
    );
}

test "trap: a plain read of a missing key is untouched by the compound rule" {
    // The deliberate divergence.  `counts[word] = counts[word] + 1`
    // reads before it writes and says nothing on its left about a
    // key being created, so it still stops on the first occurrence —
    // and it must, or every typo in a key would answer zero.
    try agreeTrap(
        \\func main():
        \\    var counts = map[str, i64]()
        \\    counts["word"] = counts["word"] + 1
        \\    assert(counts["word"] == 1)
        \\
    , .key_missing);
}

test "trap: a compound store that defines an entry and then traps frees cleanly" {
    // The define stands in front of the arithmetic, so a `u8` place
    // that goes out of range leaves the entry behind at zero and the
    // trap unwinds over a map with one more key in it than the
    // program ever managed to write.  Both engines have to agree on
    // that map, and on giving it back.
    try agreeTrap(
        \\func main():
        \\    var m = map[str, u8]()
        \\    m["a"] = 1
        \\    m["b"] -= 1
        \\    assert(len(m) == 2)
        \\
    , .integer_overflow);
}

test "trap: descending through a map key to reach a field is still a read" {
    // The boundary of the rule, and the place it is easiest to get
    // wrong.  `m["b"].value += 5` writes a *field*; the map index in
    // front of it is a step on the way down, and a step on the way
    // down is asking.  Defining it would have to invent a whole
    // `Cell` nobody wrote, which is exactly the "default values on
    // read" the ruling refused.  Only a map index that is itself the
    // place defines.
    try agreeTrap(
        \\struct Cell:
        \\    value: i64
        \\
        \\func main():
        \\    var m = map[str, Cell]()
        \\    m["a"] = Cell(value = 1)
        \\    m["b"].value += 5
        \\    assert(m["b"].value == 5)
        \\
    , .key_missing);
}

test "trap: a compound store into a list index keeps its bounds trap" {
    // Maps only.  An index is a position in something that already
    // has a shape, not a name that can be called into being; `append`
    // is the verb that grows a list.
    try agreeTrap(
        \\func main():
        \\    var xs = list[i64]()
        \\    xs[0] += 1
        \\    assert(xs[0] == 1)
        \\
    , .index_bounds);
}

test "trap: a compound store into an array cell keeps its bounds trap" {
    try agreeTrap(
        \\func main():
        \\    var cells = array[i64](2)
        \\    cells[5] += 1
        \\    assert(cells[5] == 1)
        \\
    , .index_bounds);
}

test "compound assignment computes at the place's explicit width" {
    try agreeOk(
        \\struct Pixel:
        \\    level: u8
        \\
        \\func main():
        \\    var b: u8 = 250
        \\    b += 5
        \\    assert(b == 255)
        \\    b -= 255
        \\    assert(b == 0)
        \\    var s: i16 = 32000
        \\    s += 767
        \\    assert(s == 32767)
        \\    var h: f16 = 1.0
        \\    h += 0.5
        \\    assert(h == 1.5)
        \\    var p = Pixel(level = 100)
        \\    p.level += 55
        \\    assert(p.level == 155)
        \\    var shades = array[u8](2)
        \\    shades[0] += 200
        \\    assert(shades[0] == 200)
        \\    var counts = map[str, u8]()
        \\    counts["k"] = 12
        \\    counts["k"] *= 20
        \\    assert(counts["k"] == 240)
        \\
    );
}

test "trap: compound assignment checks overflow at the place's width" {
    try agreeTrap(
        \\func main():
        \\    var b: u8 = 255
        \\    b += 1
        \\    assert(b == 0)
        \\
    , .integer_overflow);
}

test "a compound index target evaluates its index expression once" {
    // If `xs[next()]` were evaluated twice the counter would land on
    // 2 and the wrong slot would change; once, it lands on 1.
    try agreeOk(
        \\func main():
        \\    var calls: list[i64] = [0]
        \\    var xs = [100, 200, 300]
        \\    xs[bump(calls)] += 5
        \\    assert(calls[0] == 1)
        \\    assert(xs[1] == 205)
        \\    assert(xs[0] == 100)
        \\    assert(xs[2] == 300)
        \\
        \\func bump(counter: list[i64]) -> i64:
        \\    counter[0] = counter[0] + 1
        \\    return 1
        \\
    );
}

// ---------------------------------------------------------------------------
// Booleans and comparison
// ---------------------------------------------------------------------------

test "booleans: logic, short-circuit, and comparison chains" {
    try agreeOk(
        \\func main():
        \\    assert(true and true)
        \\    assert(not (true and false))
        \\    assert(true or false)
        \\    assert(not false)
        \\    assert(1 < 2 and 2 <= 2 and 3 > 2 and 3 >= 3)
        \\    assert(1 != 2)
        \\    assert(not (1 == 2))
        \\
    );
}

test "short-circuit does not evaluate the dead side" {
    try agreeOk(
        \\func boom(x: i64) -> bool:
        \\    assert(x != 0)
        \\    return true
        \\
        \\func main():
        \\    let a = false and boom(0)
        \\    assert(not a)
        \\    let b = true or boom(0)
        \\    assert(b)
        \\
    );
}

// ---------------------------------------------------------------------------
// Control flow
// ---------------------------------------------------------------------------

test "if / elif / else selects exactly one arm" {
    try agreeOk(
        \\func classify(n: i64) -> i64:
        \\    if n < 0:
        \\        return 0 - 1
        \\    elif n == 0:
        \\        return 0
        \\    else:
        \\        return 1
        \\
        \\func main():
        \\    assert(classify(0 - 5) == 0 - 1)
        \\    assert(classify(0) == 0)
        \\    assert(classify(5) == 1)
        \\
    );
}

test "while loops, break, and continue" {
    try agreeOk(
        \\func main():
        \\    var sum = 0
        \\    var i = 0
        \\    while i < 10:
        \\        i = i + 1
        \\        if i == 5:
        \\            continue
        \\        if i == 8:
        \\            break
        \\        sum = sum + i
        \\    assert(sum == 1 + 2 + 3 + 4 + 6 + 7)
        \\
    );
}

test "for-range iterates the half-open interval" {
    try agreeOk(
        \\func main():
        \\    var total: i64 = 0
        \\    for i in range(0, 5):
        \\        total = total + i
        \\    assert(total == 10)
        \\    var count = 0
        \\    for i in range(3, 3):
        \\        count = count + 1
        \\    assert(count == 0)
        \\
    );
}

test "nested loops with labeled-free break only leave the inner loop" {
    try agreeOk(
        \\func main():
        \\    var hits = 0
        \\    for i in range(0, 3):
        \\        for j in range(0, 3):
        \\            if j == 2:
        \\                break
        \\            hits = hits + 1
        \\    assert(hits == 6)
        \\
    );
}

// ---------------------------------------------------------------------------
// Functions and recursion
// ---------------------------------------------------------------------------

test "functions: parameters, returns, and recursion" {
    try agreeOk(
        \\func factorial(n: i64) -> i64:
        \\    if n <= 1:
        \\        return 1
        \\    return n * factorial(n - 1)
        \\
        \\func fib(n: i64) -> i64:
        \\    if n < 2:
        \\        return n
        \\    return fib(n - 1) + fib(n - 2)
        \\
        \\func main():
        \\    assert(factorial(5) == 120)
        \\    assert(fib(10) == 55)
        \\
    );
}

test "mutual recursion resolves regardless of declaration order" {
    try agreeOk(
        \\func is_even(n: i64) -> bool:
        \\    if n == 0:
        \\        return true
        \\    return is_odd(n - 1)
        \\
        \\func is_odd(n: i64) -> bool:
        \\    if n == 0:
        \\        return false
        \\    return is_even(n - 1)
        \\
        \\func main():
        \\    assert(is_even(10))
        \\    assert(is_odd(7))
        \\
    );
}

// ---------------------------------------------------------------------------
// Strings
// ---------------------------------------------------------------------------

test "strings: concatenation, comparison, and slicing" {
    try agreeOk(
        \\func main():
        \\    let a = "loom"
        \\    assert(a + "!" == "loom!")
        \\    assert(a == "loom")
        \\    assert(a != "luce")
        \\    assert("abc" < "abd")
        \\    assert(a[0:2] == "lo")
        \\    assert(a[2:] == "om")
        \\    assert(a[:2] == "lo")
        \\    assert(len(a) == 4)
        \\
    );
}

test "strings: UTF-8 aware slicing and byte access" {
    // Ordinary positions are Unicode scalars. The raw byte door still
    // exposes 🙂 as F0 9F 99 82 when encoding work needs it.
    try agreeOk(
        \\func main():
        \\    let s = "a🙂b"
        \\    assert(len(s) == 3)
        \\    assert(len(bytes(s)) == 6)
        \\    assert(s[0:1] == "a")
        \\    assert(s[1:2] == "🙂")
        \\    assert(s[1] == '🙂')
        \\    assert(s.byte_at(0) == 97)
        \\    assert(s.byte_at(1) == 240)
        \\
    );
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

test "conversions: text, parsing, and char code points" {
    try agreeOk(
        \\func main():
        \\    assert(str(42) == "42")
        \\    assert(str(0 - 7) == "-7")
        \\    assert(str(true) == "true")
        \\    assert(str(false) == "false")
        \\    assert((parse_i64("100") else 0) == 100)
        \\    assert((parse_f64("1.5") else 0.0) == 1.5)
        \\    assert(str(char(65)) == "A")
        \\    assert(u32('A') == u32(65))
        \\    assert(str(char(955)) == "λ")
        \\    assert(u32('λ') == u32(955))
        \\
    );
}

test "a char-to-u32 conversion is a compile-time constant" {
    var compiled = try agree.program(
        \\func main():
        \\    let text = "(x)"
        \\    assert(u32(text.byte_at(0)) == u32('('))
        \\
    );
    defer compiled.deinit();
    var folded = false;
    for (compiled.functions) |function| {
        for (function.instructions) |instruction| {
            // `(` is 40, and the fold has to have left it somewhere.
            // Looking only for the absence of work could pass on an
            // empty program and prove nothing.
            if (instruction == .const_integer and instruction.const_integer == 40) folded = true;
        }
    }
    try testing.expect(folded);
}

test "char-to-u32 conversions fold in file-scope constants" {
    try agreeOk(
        \\const open_paren = u32('(')
        \\const lambda = u32('λ')
        \\
        \\func main():
        \\    assert(open_paren == u32(40))
        \\    assert(lambda == u32(955))
        \\    assert(u32("(a)".byte_at(0)) == open_paren)
        \\
    );
}

// ---------------------------------------------------------------------------
// string interpolation (f-strings)
// ---------------------------------------------------------------------------

test "f-strings interpolate names, expressions, and every scalar" {
    try agreeOk(
        \\func main():
        \\    let x = 7
        \\    let y = 3
        \\    assert(f"x = {x}, y = {y}" == "x = 7, y = 3")
        \\    assert(f"sum = {x + y}" == "sum = 10")
        \\    assert(f"{x}" == "7")
        \\    assert(f"{x}{y}" == "73")
        \\    let name = "loom"
        \\    assert(f"hi {name}!" == "hi loom!")
        \\    let flag = true
        \\    assert(f"flag={flag}" == "flag=true")
        \\    assert(f"ratio={2.5}" == "ratio=2.5")
        \\
    );
}

test "f-strings: empty, no holes, escapes, literal braces, nested strings" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    assert(f"" == "")
        \\    assert(f"plain" == "plain")
        \\    assert(f"tab\tend" == "tab\tend")
        \\    assert(f"braces: {{ }}" == "braces: { }")
        \\    let name = "x"
        \\    assert(f"hello { name }" == "hello x")
        \\    assert(f"{name + "!"}" == "x!")
        \\    let n = 5
        \\    assert(f"{n * n} squared" == "25 squared")
        \\    assert(f"{ len({ "key": name }) }" == "1")
        \\    assert(f"{ 2.5 : .1f }" == "2.5")
        \\
    );
}

test "f-strings compose with methods and calls in holes" {
    try agreeOk(
        \\import std.strings
        \\
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func main():
        \\    let s = "Loom"
        \\    assert(f"{s.lower()} and {s.upper()}" == "loom and LOOM")
        \\    assert(f"twice(21) = {twice(21)}" == "twice(21) = 42")
        \\    var xs = [1, 2, 3]
        \\    assert(f"len is {len(xs)}" == "len is 3")
        \\
    );
}

// ---------------------------------------------------------------------------
// Structs
// ---------------------------------------------------------------------------

test "structs: construction, field read, functional update, value copy" {
    try agreeOk(
        \\struct Point:
        \\    x: i64
        \\    y: i64
        \\
        \\func main():
        \\    var p = Point(x = 1, y = 2)
        \\    assert(p.x == 1 and p.y == 2)
        \\    p.x = 10
        \\    assert(p.x == 10 and p.y == 2)
        \\    let q = p
        \\    p.y = 99
        \\    assert(q.y == 2)
        \\    assert(p == p)
        \\    assert(q != p)
        \\
    );
}

test "structs: namespaced functions and nested structs" {
    try agreeOk(
        \\struct Vec:
        \\    x: i64
        \\    y: i64
        \\
        \\    static func add(a: Vec, b: Vec) -> Vec:
        \\        return Vec(x = a.x + b.x, y = a.y + b.y)
        \\
        \\struct Line:
        \\    from: Vec
        \\    to: Vec
        \\
        \\func main():
        \\    let sum = Vec.add(Vec(x = 1, y = 2), Vec(x = 3, y = 4))
        \\    assert(sum.x == 4 and sum.y == 6)
        \\    let line = Line(from = Vec(x = 0, y = 0), to = sum)
        \\    assert(line.to.y == 6)
        \\
    );
}

// ---------------------------------------------------------------------------
// Answering more than one thing
// ---------------------------------------------------------------------------
//
// `-> (A, B)`, `return a, b`, `let low, high = f()`, and the later
// polish form `low, high = f()`.  **There is no tuple**: the values
// exist only in flight, produced by a return and consumed by one
// destructuring statement (docs/RETURNS.md, docs/SELF.md).
//
// Underneath they are one compiler-synthesized struct, which is why
// the oracle needed no edit for any of this either.

test "returns: a shape is declared, returned, and bound" {
    try agreeOk(
        \\func minmax(xs: list[i64]) -> (i64, i64):
        \\    var low = xs[0]
        \\    var high = xs[0]
        \\    for value in xs:
        \\        low = min(low, value)
        \\        high = max(high, value)
        \\    return low, high
        \\
        \\func main():
        \\    var xs: list[i64] = [3, 1, 4, 1, 5]
        \\    let low, high = minmax(xs)
        \\    assert(low == 1 and high == 5)
        \\    # `var` governs the whole bind, and both names reassign.
        \\    var a, b = minmax(xs)
        \\    a = a + 1
        \\    b = b + 1
        \\    assert(a == 2 and b == 6)
        \\
    );
}

test "returns: three values, mixed types, and a shape of shapes' worth of nesting" {
    try agreeOk(
        \\func spread(n: i64) -> (i64, f64, str):
        \\    return n, f64(n) / 2.0, str(n)
        \\
        \\func main():
        \\    let count, fraction, written = spread(7)
        \\    assert(count == 7)
        \\    assert(fraction == 3.5)
        \\    assert(written == "7")
        \\
    );
}

test "returns: a discarded call is a statement temporary and dies with its statement" {
    // S3/S19, unextended: under the lowering the discarded value is
    // one struct, so the walk that already releases an object-carrying
    // struct temporary releases the whole shape.  The leak census is
    // what proves it.
    try agreeOk(
        \\func two() -> (list[i64], list[i64]):
        \\    var head: list[i64] = [1]
        \\    var tail: list[i64] = [2]
        \\    return head, tail
        \\
        \\func main():
        \\    two()
        \\    two()
        \\    assert(true)
        \\
    );
}

test "returns: each value moves, and the caller's two names own one each" {
    try agreeOk(
        \\func halves(n: i64) -> (list[i64], list[i64]):
        \\    var head = [n]
        \\    var tail = [n + 1]
        \\    return head, tail
        \\
        \\func main():
        \\    let head, tail = halves(7)
        \\    assert(head[0] == 7 and tail[0] == 8)
        \\    head.append(9)
        \\    assert(len(head) == 2 and len(tail) == 1)
        \\
    );
}

test "returns: T! composes, and try is the only composition there is" {
    try agreeOk(
        \\func pair(n: i64) -> (i64, i64)!:
        \\    if n < 0:
        \\        error("negative")
        \\    return n, n * 2
        \\
        \\func doubled(n: i64) -> (i64, i64)!:
        \\    let a, b = try pair(n)
        \\    return b, a
        \\
        \\func main() -> !:
        \\    let x, y = try pair(3)
        \\    assert(x == 3 and y == 6)
        \\    let p, q = try doubled(4)
        \\    assert(p == 8 and q == 4)
        \\    # A statement discards the values; the handler runs where
        \\    # it raised, and supplies none.
        \\    pair(-1) catch:
        \\        assert(true)
        \\
    );
}

test "try in a subexpression binds tight, runs left to right, and stops at the first error" {
    // The ruling issue #11 asked for, written as behavior (docs/FAILURE.md):
    // `try` is an expression prefix legal in any expression position; it
    // binds to the tightest following fallible call, tighter than any
    // binary operator; operands still evaluate left to right; and the
    // first error abandons the whole enclosing statement — later
    // operands never run, which the printed trace is the proof of.
    try agree.prints(
        \\func noted(tag: str, value: i64) -> i64!:
        \\    if value < 0:
        \\        error("refused " + tag)
        \\    print("ran " + tag)
        \\    return value
        \\
        \\func chain() -> i64!:
        \\    return (try noted("f", 5)) + (try noted("g", -1)) + (try noted("h", 9))
        \\
        \\func main() -> !:
        \\    # Tighter than +: each try takes one call, not the sum.
        \\    let total = try noted("a", 4) + try noted("b", 2)
        \\    print(str(total))
        \\    # Legal inside a list literal and an argument position.
        \\    let held = [try noted("c", 7), try noted("d", 1)]
        \\    print(str(len(held) + (try noted("e", 0))))
        \\    # Left to right, stopping at the first error: "f" runs,
        \\    # "g" raises, "h" never runs.  The catch lives one call
        \\    # out, because try already consumed each call's
        \\    # fallibility — a statement whose errors are all tried has
        \\    # nothing left for a catch to guard, and says so.
        \\    var landed = -1
        \\    landed = chain() catch reason:
        \\        print(reason)
        \\    assert(landed == -1)
        \\    print("after")
        \\
    ,
        \\ran a
        \\ran b
        \\6
        \\ran c
        \\ran d
        \\ran e
        \\2
        \\ran f
        \\refused g
        \\after
        \\
    );
}

test "returns: T? is an ordinary element of a shape" {
    // Absence *is* a value, so a `T?` among the elements needs no rule
    // at all — while `-> (i64, i64)?` is refused, because there the
    // `?` would be marking the shape (docs/RETURNS.md §2).
    try agreeOk(
        \\func lookup(m: map[str, i64], key: str) -> (i64?, bool):
        \\    if m.has(key):
        \\        return m[key], true
        \\    return none, false
        \\
        \\func main():
        \\    var ages = map[str, i64]()
        \\    ages["ada"] = 36
        \\    let found, present = lookup(ages, "ada")
        \\    assert(present and (found else 0) == 36)
        \\    let missing, there = lookup(ages, "bob")
        \\    assert(not there and missing == none)
        \\
    );
}

test "returns: a shape crosses a loop as two vars, and the body gets shorter" {
    // The case docs/RETURNS.md's first rule tripped on: loop-carried is
    // not disqualifying, and two `var`s carry a pair as well as one
    // struct did.
    try agreeOk(
        \\func step(value: i64, at: i64) -> (i64, i64):
        \\    return value + at, at + 1
        \\
        \\func main():
        \\    var value, at = step(0, 0)
        \\    while at < 5:
        \\        value, at = step(value, at)
        \\    assert(at == 5)
        \\    assert(value == 10)
        \\
    );
}

test "returns: existing vars receive one snapshot through every call surface" {
    try agreeOk(
        \\struct Pairs:
        \\    static func swapped(left: i64, right: i64) -> (i64, i64):
        \\        return right, left
        \\
        \\struct PairSource:
        \\    left: i64
        \\    right: i64
        \\
        \\    func values() -> (i64, i64):
        \\        return self.left, self.right
        \\
        \\func advanced(value: i64, at: i64) -> (i64, i64):
        \\    return value + at, at + 1
        \\
        \\func main():
        \\    var left: i64 = 10
        \\    var right: i64 = 20
        \\    left, right = Pairs.swapped(left, right)
        \\    assert(left == 20 and right == 10)
        \\    left, right = advanced(left, right)
        \\    assert(left == 30 and right == 11)
        \\    let source = PairSource(left = 7, right = 8)
        \\    left, right = source.values()
        \\    assert(left == 7 and right == 8)
        \\
    );
}

test "returns: assignment keeps exact types and prepares str storage before replacement" {
    try agreeOk(
        \\func mixed() -> (f64, i64?, i64?):
        \\    return 7, 9, none
        \\
        \\func flipped(left: str, right: str) -> (str, str):
        \\    return right, left
        \\
        \\func main():
        \\    var wide: f64 = 0.0
        \\    var present: i64? = none
        \\    var missing: i64? = 1
        \\    wide, present, missing = mixed()
        \\    assert(wide == 7.0)
        \\    assert((present else 0) + 1 == 10)
        \\    assert((missing else 0) == 0)
        \\    var inside = "left"
        \\    var outside = "a string long enough to own outside bytes"
        \\    inside, outside = flipped(inside, outside)
        \\    assert(inside == "a string long enough to own outside bytes")
        \\    assert(outside == "left")
        \\
    );
}

test "returns: try and catch commit both replacement stores or neither" {
    try agreeOk(
        \\func pair(value: i64) -> (i64, i64)!:
        \\    if value < 0:
        \\        error("negative")
        \\    return value, value * 2
        \\
        \\func forwarded(value: i64) -> (i64, i64)!:
        \\    var left: i64 = 100
        \\    var right: i64 = 200
        \\    left, right = try pair(value)
        \\    return left, right
        \\
        \\func main() -> !:
        \\    var left: i64 = 10
        \\    var right: i64 = 20
        \\    left, right = pair(3) catch:
        \\        assert(false)
        \\    assert(left == 3 and right == 6)
        \\    left, right = pair(-1) catch reason:
        \\        assert(reason == "negative")
        \\        assert(left == 3 and right == 6)
        \\    assert(left == 3 and right == 6)
        \\    left, right = try forwarded(4)
        \\    assert(left == 4 and right == 8)
        \\
    );
}

test "returns: a failed assignment keeps RHS side effects but commits no replacements" {
    try agreeOk(
        \\struct Counter:
        \\    value: i64
        \\
        \\    func bump() -> i64:
        \\        self.value += 1
        \\        return self.value
        \\
        \\func risky(value: i64) -> (Counter, i64)!:
        \\    if value >= 0:
        \\        error("failed")
        \\    return Counter(value = value), value
        \\
        \\func main():
        \\    var counter = Counter(value = 0)
        \\    var result: i64 = 7
        \\    counter, result = risky(counter.bump()) catch:
        \\        assert(counter.value == 1)
        \\        assert(result == 7)
        \\    assert(counter.value == 1)
        \\    assert(result == 7)
        \\
    );
}

test "returns: guarded assignment joins optional facts from both continuing paths" {
    try agreeOk(
        \\func risky(ok: bool) -> (i64, i64)!:
        \\    if not ok:
        \\        error("no value")
        \\    return 4, 5
        \\
        \\func fallback() -> (i64, i64):
        \\    return 10, 20
        \\
        \\func resolved(ok: bool) -> i64:
        \\    var left: i64? = none
        \\    var right: i64 = 0
        \\    left, right = risky(ok) catch:
        \\        left, right = fallback()
        \\    return left + right
        \\
        \\func returned_handler(ok: bool) -> i64:
        \\    var left: i64? = none
        \\    var right: i64 = 0
        \\    left, right = risky(ok) catch:
        \\        return -1
        \\    return left + right
        \\
        \\func main():
        \\    assert(resolved(true) == 9)
        \\    assert(resolved(false) == 30)
        \\    assert(returned_handler(true) == 9)
        \\    assert(returned_handler(false) == -1)
        \\
    );
}

// ---------------------------------------------------------------------------
// Methods: implied `self`
// ---------------------------------------------------------------------------
//
// A plain member is a method and receives `self` implicitly; a
// namespace function is marked `static` and called through the type.

test "methods: a receiver reads its struct beside a static namespace function" {
    try agreeOk(
        \\struct Point:
        \\    x: f64
        \\    y: f64
        \\
        \\    func length() -> f64:
        \\        return sqrt(self.x * self.x + self.y * self.y)
        \\
        \\    func plus(other: Point) -> Point:
        \\        return Point(x = self.x + other.x, y = self.y + other.y)
        \\
        \\    static func origin() -> Point:
        \\        return Point(x = 0.0, y = 0.0)
        \\
        \\func main():
        \\    let p = Point(x = 3.0, y = 4.0)
        \\    assert(p.length() == 5.0)
        \\    let q = p.plus(Point(x = 1.0, y = 1.0))
        \\    assert(q.x == 4.0 and q.y == 5.0)
        \\    # An explicitly static namespace function beside methods.
        \\    assert(Point.origin().length() == 0.0)
        \\    # And a method on a call result, which needs no place.
        \\    assert(Point.origin().plus(p).length() == 5.0)
        \\
    );
}

test "methods: a reader sees the receiver value without changing it" {
    try agreeOk(
        \\struct Counter:
        \\    count: i64
        \\
        \\    func bumped() -> Counter:
        \\        var next = self
        \\        next.count = next.count + 1
        \\        return next
        \\
        \\func main():
        \\    let one = Counter(count = 1)
        \\    let two = one.bumped()
        \\    assert(two.count == 2)
        \\    # A reader does not change `one`.
        \\    assert(one.count == 1)
        \\
    );
}

test "methods: a receiver may be a field, an element, or a chain of both" {
    try agreeOk(
        \\struct Point:
        \\    x: i64
        \\
        \\    func doubled() -> i64:
        \\        return self.x * 2
        \\
        \\struct Box:
        \\    corner: Point
        \\
        \\func main():
        \\    let box = Box(corner = Point(x = 3))
        \\    assert(box.corner.doubled() == 6)
        \\    var cells = [Point(x = 5)]
        \\    assert(cells[0].doubled() == 10)
        \\
    );
}

test "methods: a method may take and answer objects, and ownership is the plain-call rule" {
    try agreeOk(
        \\struct Tally:
        \\    total: i64
        \\
        \\    func over(values: list[i64]) -> i64:
        \\        var sum = self.total
        \\        for value in values:
        \\            sum = sum + value
        \\        return sum
        \\
        \\    func spread() -> list[i64]:
        \\        var made = [self.total, self.total]
        \\        return made
        \\
        \\func main():
        \\    let tally = Tally(total = 10)
        \\    var numbers: list[i64] = [1, 2, 3]
        \\    assert(tally.over(numbers) == 16)
        \\    var pair = tally.spread()
        \\    assert(len(pair) == 2 and pair[0] == 10)
        \\
    );
}

test "methods: method arguments land at their declared types" {
    try agreeOk(
        \\struct Point:
        \\    x: i64
        \\
        \\    func pick(fallback: i64?) -> i64:
        \\        return fallback else self.x
        \\
        \\func main():
        \\    let p = Point(x = 7)
        \\    assert(p.pick(none) == 7)
        \\    assert(p.pick(3) == 3)
        \\
    );
}

test "methods: a literal argument lands at the parameter's width" {
    try agreeOk(
        \\struct Gauge:
        \\    reading: f64
        \\
        \\    func matches(level: f64) -> bool:
        \\        return self.reading == level
        \\
        \\func main():
        \\    let gauge = Gauge(reading = 0.1)
        \\    assert(gauge.matches(0.1))
        \\
    );
}

// ---------------------------------------------------------------------------
// Named arguments (docs/ARGS.md)
// ---------------------------------------------------------------------------
//
// Every parameter has a name, and a call site may use it: positional
// arguments fill slots left to right, the first named argument ends
// the positional run (D4), names may reorder (D5), and names are never
// required (D1).  Names die in stage 4 — the specs below run the same
// MIR a positional call runs, which is what the printer test in
// compile/test.zig pins byte for byte.

test "named arguments: a call may name, mix, and reorder its arguments" {
    try agreeOk(
        \\func size(width: i64, height: i64, deep: bool) -> i64:
        \\    if deep:
        \\        return width * height * 2
        \\    return width * height
        \\
        \\func main():
        \\    let flat = size(3, 4, false)
        \\    assert(size(width = 3, height = 4, deep = false) == flat)
        \\    assert(size(3, height = 4, deep = false) == flat)
        \\    assert(size(3, 4, deep = false) == flat)
        \\    assert(size(deep = false, height = 4, width = 3) == flat)
        \\    assert(size(height = 4, width = 3, deep = true) == flat * 2)
        \\
    );
}

test "named arguments: evaluation stays in written order, binding lands by name" {
    // D5's clause, proven rather than stated: `f(b = one(), a = two())`
    // runs one() first, and each value still lands on the slot it
    // names.
    try agreeOk(
        \\func logged(log: list[i64], value: i64) -> i64:
        \\    log.append(value)
        \\    return value
        \\
        \\func pair(a: i64, b: i64) -> i64:
        \\    return a * 10 + b
        \\
        \\func main():
        \\    var log = list[i64]()
        \\    let got = pair(b = logged(log, 7), a = logged(log, 3))
        \\    assert(got == 37)
        \\    assert(log[0] == 7 and log[1] == 3)
        \\
    );
}

test "named arguments: all four spellings of a user call take them" {
    // One resolver behind plain, namespaced, static and method calls
    // (docs/ARGS.md §3) — including std module functions, which are
    // ordinary Luce declarations.
    try agreeOk(
        \\import std.strings
        \\
        \\struct Point:
        \\    x: i64
        \\
        \\    func plus(other: i64, twice: bool) -> i64:
        \\        if twice:
        \\            return self.x + other * 2
        \\        return self.x + other
        \\
        \\    static func added(left: i64, right: i64) -> i64:
        \\        return left + right
        \\
        \\func multiplied(left: i64, right: i64) -> i64:
        \\    return left * right
        \\
        \\func main():
        \\    let p = Point(x = 10)
        \\    assert(p.plus(other = 5, twice = false) == 15)
        \\    assert(p.plus(twice = true, other = 5) == 20)
        \\    assert(Point.added(right = 5, left = 10) == 15)
        \\    assert(multiplied(right = 4, left = 3) == 12)
        \\    assert((strings.find(s = "abcb", needle = "b") else -1) == 1)
        \\    assert((strings.find(needle = "b", s = "abcb") else -1) == 1)
        \\
    );
}

test "named arguments: a named literal lands at the slot it names" {
    // The permutation runs before anything is lowered (docs/ARGS.md
    // §4): `f(wide = 0.1)` with an f64 parameter reads binary64's
    // 0.1, regardless of the argument's written position.
    try agreeOk(
        \\func held(narrow: f32, wide: f64) -> bool:
        \\    return wide == 0.1 and f64(narrow) != 0.1
        \\
        \\func main():
        \\    # f64(f32(0.1)) is not binary64's direct 0.1, so the
        \\    # assertion holds only if each literal landed at the
        \\    # width of the slot it *names* — written in the other
        \\    # order.
        \\    assert(held(wide = 0.1, narrow = 0.1))
        \\
    );
}

test "defaults: an omitted trailing argument is filled from the declaration" {
    // D2 and D3 of docs/ARGS.md: this value default is a folded
    // compile-time constant, materialised at each call site, and the
    // suffix a call omits is the suffix the declaration filled in — by
    // count or by name.  Container defaults instead share a program
    // root, as constants_spec proves.
    try agreeOk(
        \\func grown(base: i64, step: i64 = 5, twice: bool = false) -> i64:
        \\    var total = base + step
        \\    if twice:
        \\        total = total * 2
        \\    return total
        \\
        \\func main():
        \\    assert(grown(1) == 6)
        \\    assert(grown(1, 2) == 3)
        \\    assert(grown(1, 2, true) == 6)
        \\    assert(grown(1, twice = true) == 12)
        \\    assert(grown(base = 1, step = 0) == 1)
        \\
    );
}

test "defaults: a constant, a str, a struct value, and none all serve" {
    // The value-default forms exercised here are other file-scope
    // constants, string literals, value-struct construction and,
    // through D9, `none` where the parameter says what it is absent of.
    // Borrowed flat-container defaults are covered in constants_spec.
    try agreeOk(
        \\const step_default = 4
        \\
        \\struct Point:
        \\    x: i64
        \\    y: i64
        \\
        \\func stepped(base: i64, step: i64 = step_default * 2) -> i64:
        \\    return base + step
        \\
        \\func greet(name: str = "loom") -> str:
        \\    return "hi " + name
        \\
        \\func corner(p: Point = Point(x = 1, y = 2)) -> i64:
        \\    return p.x + p.y
        \\
        \\func pick(value: i64? = none, fallback: i64 = 7) -> i64:
        \\    return value else fallback
        \\
        \\func main():
        \\    assert(stepped(1) == 9)
        \\    assert(greet() == "hi loom")
        \\    assert(greet("luce") == "hi luce")
        \\    assert(corner() == 3)
        \\    assert(corner(Point(x = 5, y = 5)) == 10)
        \\    assert(pick() == 7)
        \\    assert(pick(3) == 3)
        \\    assert(pick(fallback = 9) == 9)
        \\
    );
}

test "defaults: methods fill omitted slots after the implicit receiver" {
    try agreeOk(
        \\struct Counter:
        \\    count: i64
        \\
        \\    func bumped(step: i64 = 1) -> i64:
        \\        return self.count + step
        \\
        \\func main():
        \\    let counter = Counter(count = 10)
        \\    assert(counter.bumped() == 11)
        \\    assert(counter.bumped(5) == 15)
        \\    assert(counter.bumped(step = 3) == 13)
        \\
    );
}

test "struct field defaults: the declaration absorbs the invariant" {
    // The State case of docs/ARGS.md: fields at the zero of their
    // type move from the construction site to the declaration, where
    // a second construction site cannot get them wrong (D8).
    try agreeOk(
        \\struct State:
        \\    path: str
        \\    cursor: i64 = 0
        \\    dirty: bool = false
        \\    message: str = ""
        \\
        \\func main():
        \\    let fresh = State(path = "notes.txt")
        \\    assert(fresh.cursor == 0)
        \\    assert(not fresh.dirty)
        \\    assert(fresh.message == "")
        \\    let seen = State(path = "notes.txt", dirty = true)
        \\    assert(seen.dirty and seen.cursor == 0)
        \\
    );
}

test "struct field defaults: a struct of nothing but defaults constructs bare" {
    try agreeOk(
        \\struct Options:
        \\    depth: i64 = 3
        \\    wide: bool = false
        \\
        \\func main():
        \\    let plain = Options()
        \\    assert(plain.depth == 3 and not plain.wide)
        \\    let tuned = Options(depth = 9)
        \\    assert(tuned.depth == 9 and not tuned.wide)
        \\
    );
}

test "struct field defaults: constants and parameter defaults reach them" {
    // One folder behind all three clauses (docs/ARGS.md D2, D8): a
    // file-scope constant may construct a struct leaning on its
    // defaults, and a parameter default may too.
    try agreeOk(
        \\struct Corner:
        \\    x: i64 = 1
        \\    y: i64 = 2
        \\
        \\const origin = Corner()
        \\
        \\func shifted(by: Corner = Corner(y = 5)) -> i64:
        \\    return by.x + by.y
        \\
        \\func main():
        \\    assert(origin.x == 1 and origin.y == 2)
        \\    assert(shifted() == 6)
        \\    assert(shifted(Corner(x = 3, y = 3)) == 6)
        \\
    );
}

test "builtins: the table is the signature, so a call may name its slots" {
    // docs/ARGS.md D10: free builtins take names from their signature
    // table — `len(value = …)` is legal, and `min(b = …, a = …)`
    // reorders like any user call.
    try agreeOk(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    assert(len(value = xs) == 3)
        \\    assert(min(a = 3, b = 9) == 3)
        \\    assert(min(b = 9, a = 3) == 3)
        \\    assert(max(3, b = 9) == 9)
        \\    assert(clamp(value = 42, low = 0, high = 10) == 10)
        \\    assert(abs(value = -7) == 7)
        \\    assert(char(value = 65) == 'A')
        \\    assert(u32(value = 'A') == u32(65))
        \\    assert(str(value = 'A') == "A")
        \\    assert(i64(value = 2.5) == 2)
        \\
    );
}

test "methods: a method can fail, and try and catch reach it through the receiver" {
    try agreeOk(
        \\struct Reader:
        \\    limit: i64
        \\
        \\    func check(n: i64) -> i64!:
        \\        if n > self.limit:
        \\            error("over the limit")
        \\        return n
        \\
        \\func under() -> i64!:
        \\    let reader = Reader(limit = 5)
        \\    return try reader.check(3)
        \\
        \\func main():
        \\    let reader = Reader(limit = 5)
        \\    assert((under() catch 0) == 3)
        \\    assert((reader.check(9) catch -1) == -1)
        \\
    );
}

// ---------------------------------------------------------------------------
// Writing methods: inferred implied `self`
// ---------------------------------------------------------------------------
//
// A plain member that writes `self` is inferred as a writer. Its
// receiver is an in-place mutable binding, separate from its declared
// return values.

test "methods: direct field and whole-self writes are inferred" {
    try agreeOk(
        \\struct Point:
        \\    x: f64
        \\    y: f64
        \\
        \\    func scale(factor: f64):
        \\        self.x = self.x * factor
        \\        self.y = self.y * factor
        \\
        \\    func reset():
        \\        # A writing method may replace its whole receiver.
        \\        self = Point(x = 0.0, y = 0.0)
        \\
        \\func main():
        \\    var p = Point(x = 1.0, y = 2.0)
        \\    p.scale(2.0)
        \\    assert(p.x == 2.0 and p.y == 4.0)
        \\    # A copy taken before the call is untouched by it.
        \\    let before = p
        \\    p.scale(0.5)
        \\    assert(p.x == 1.0 and before.x == 2.0)
        \\    p.reset()
        \\    assert(p.x == 0.0 and p.y == 0.0)
        \\
    );
}

test "methods: an inferred writer may return a value and call another writer" {
    try agreeOk(
        \\struct Rng:
        \\    state: i64
        \\
        \\    func next() -> i64:
        \\        self.state = self.state * 48271 % 2147483647
        \\        return self.state
        \\
        \\    func in_range(low: i64, high: i64) -> i64:
        \\        if high <= low:
        \\            trap("in_range needs low < high")
        \\        return low + self.next() % (high - low)
        \\
        \\func main():
        \\    var rng = Rng(state = 42)
        \\    let roll = rng.in_range(1, 7)
        \\    assert(roll >= 1 and roll < 7)
        \\    # The receiver write happened in place.
        \\    assert(rng.state == 2027382)
        \\    let second = rng.next()
        \\    assert(second == rng.state)
        \\    assert(second != 2027382)
        \\    # At statement position the declared value is discarded
        \\    # while the receiver write still happens.
        \\    let third = rng.state
        \\    rng.next()
        \\    assert(rng.state != third)
        \\
    );
}

test "methods: a writer accepts a bare var receiver" {
    try agreeOk(
        \\struct Counter:
        \\    n: i64
        \\
        \\    func bump():
        \\        self.n = self.n + 1
        \\
        \\func main():
        \\    var c = Counter(n = 1)
        \\    c.bump()
        \\    c.bump()
        \\    assert(c.n == 3)
        \\
    );
}

test "methods: an error before a receiver write leaves it unchanged" {
    try agreeOk(
        \\struct Meter:
        \\    reading: i64
        \\
        \\    func take(n: i64) -> i64!:
        \\        if n < 0:
        \\            error("negative")
        \\        self.reading = self.reading + n
        \\        return self.reading
        \\
        \\func main():
        \\    var meter = Meter(reading = 10)
        \\    let ok = meter.take(5) catch -1
        \\    assert(ok == 15 and meter.reading == 15)
        \\    let bad = meter.take(-1) catch -1
        \\    assert(bad == -1)
        \\    # The error happened before the write.
        \\    assert(meter.reading == 15)
        \\
    );
}

test "methods: readers and writers share the method call surface" {
    try agreeOk(
        \\struct Point:
        \\    x: i64
        \\
        \\    func doubled() -> i64:
        \\        return self.x * 2
        \\
        \\    func grow():
        \\        self.x = self.x + 1
        \\
        \\func main():
        \\    var p = Point(x = 3)
        \\    assert(p.doubled() == 6)
        \\    p.grow()
        \\    assert(p.x == 4)
        \\
    );
}

// ---------------------------------------------------------------------------
// Nested-place assignment
// ---------------------------------------------------------------------------

test "chained assignment through nested struct fields" {
    try agreeOk(
        \\struct Inner:
        \\    n: i64
        \\
        \\struct Outer:
        \\    label: str
        \\    inner: Inner
        \\
        \\func main():
        \\    var o = Outer(label = "x", inner = Inner(n = 1))
        \\    o.inner.n = 42
        \\    assert(o.inner.n == 42)
        \\    assert(o.label == "x")
        \\    o.inner.n += 8
        \\    assert(o.inner.n == 50)
        \\    let snapshot = o
        \\    o.inner.n = 0
        \\    assert(snapshot.inner.n == 50)
        \\
    );
}

test "chained assignment into struct elements of lists and arrays" {
    try agreeOk(
        \\struct Cell:
        \\    value: i64
        \\
        \\func main():
        \\    var cells = [Cell(value = 10), Cell(value = 20)]
        \\    cells[1].value = 99
        \\    assert(cells[1].value == 99)
        \\    assert(cells[0].value == 10)
        \\    cells[0].value += 5
        \\    assert(cells[0].value == 15)
        \\    var grid = array[Cell](2, 2)
        \\    grid[1, 1].value = 7
        \\    assert(grid[1, 1].value == 7)
        \\    assert(grid[0, 0].value == 0)
        \\
    );
}

test "a chained index place evaluates its subscript once" {
    try agreeOk(
        \\struct Cell:
        \\    value: i64
        \\
        \\func bump(counter: list[i64]) -> i64:
        \\    counter[0] = counter[0] + 1
        \\    return 1
        \\
        \\func main():
        \\    var calls: list[i64] = [0]
        \\    var cells = [Cell(value = 100), Cell(value = 200)]
        \\    cells[bump(calls)].value += 5
        \\    assert(calls[0] == 1)
        \\    assert(cells[1].value == 205)
        \\    assert(cells[0].value == 100)
        \\
    );
}

// ---------------------------------------------------------------------------
// Collections
// ---------------------------------------------------------------------------

test "lists: literals, indexing, growth, and iteration" {
    try agreeOk(
        \\func main():
        \\    var xs = [10, 20, 30]
        \\    assert(len(xs) == 3)
        \\    assert(xs[1] == 20)
        \\    xs[1] = 25
        \\    assert(xs[1] == 25)
        \\    xs.append(40)
        \\    assert(xs[3] == 40)
        \\    xs.insert(0, 5)
        \\    assert(xs[0] == 5 and len(xs) == 5)
        \\    xs.remove(0)
        \\    assert(xs[0] == 10)
        \\    assert(xs.pop() == 40)
        \\    var total = 0
        \\    for x in xs:
        \\        total = total + x
        \\    assert(total == 10 + 25 + 30)
        \\
    );
}

test "lists: the inline path answers what the call answered, at every width" {
    // Element access and `append` on a list are generated rather than
    // called (docs/CODEGEN.md), and the two engines are how that is
    // held to the semantics: the oracle still calls `libluce_rt` for
    // every one of these, so any disagreement is the lowering's.
    //
    // What this walks is the edges the inline path has and the call
    // did not: the growth boundary, crossed hundreds of times with four
    // element representations, and the buffer moving under a handle that
    // another name also holds.
    try agreeOk(
        \\func main():
        \\    var small = list[u8]()
        \\    var wide = list[i64]()
        \\    var real = list[f64]()
        \\    var flags = list[bool]()
        \\    for i in range(0, 500):
        \\        small.append(u8(i % 251))
        \\        wide.append(i * 7)
        \\        real.append(f64(i) / 4.0)
        \\        flags.append(i % 3 == 0)
        \\    assert(len(small) == 500 and len(flags) == 500)
        \\    var total: i64 = 0
        \\    var set = 0
        \\    for i in range(0, 500):
        \\        assert(small[i] == u8(i % 251))
        \\        assert(real[i] == f64(i) / 4.0)
        \\        total += wide[i]
        \\        if flags[i]:
        \\            set += 1
        \\    assert(total == 500 * 499 // 2 * 7)
        \\    assert(set == 167)
        \\
    );
}

test "lists: an append through one name is seen through the other" {
    // The buffer a list holds moves under `append`, so a resolved view
    // of it is only ever reused across instructions that cannot move
    // one — every call and every append end the run.  This is the
    // program that would catch a view kept one instruction too long.
    try agreeOk(
        \\func grow(target: list[i64], many: i64):
        \\    for i in range(0, many):
        \\        target.append(i)
        \\
        \\func main():
        \\    var xs = list[i64]()
        \\    let same = xs
        \\    xs.append(1)
        \\    same.append(2)
        \\    assert(xs[1] == 2 and len(same) == 2)
        \\    # The callee grows it far past the eight elements the
        \\    # first allocation holds; the caller's next read must be
        \\    # of the buffer that came back, not the one it lent.
        \\    grow(xs, 300)
        \\    assert(len(xs) == 302)
        \\    assert(xs[301] == 299)
        \\    # And an append between two reads of the same list, in one
        \\    # statement's worth of code.
        \\    let first = xs[0]
        \\    xs.append(first)
        \\    assert(xs[302] == 1)
        \\
    );
}

test "trap: an inline append refuses a list that was never made" {
    try agreeTrap(
        \\func main():
        \\    var xs: list[i64]
        \\    xs.append(1)
        \\
    , .null_object);
}

test "maps: upsert, lookup, membership, keys in insertion order" {
    try agreeOk(
        \\func main():
        \\    var m = map[str, i64]()
        \\    m["a"] = 1
        \\    m["b"] = 2
        \\    m["a"] = 3
        \\    assert(len(m) == 2)
        \\    assert(m["a"] == 3)
        \\    assert(m.has("b"))
        \\    assert(not m.has("z"))
        \\    var order = builder()
        \\    for k in m.keys():
        \\        order.append(k)
        \\    assert(order.build() == "ab")
        \\    m.remove("a")
        \\    assert(not m.has("a") and len(m) == 1)
        \\
    );
}

test "maps: for key, value iteration, values(), and get with default" {
    try agreeOk(
        \\func main():
        \\    var m = map[str, i64]()
        \\    m["a"] = 1
        \\    m["b"] = 2
        \\    m["c"] = 3
        \\    var keys = builder()
        \\    var total: i64 = 0
        \\    for k, v in m:
        \\        keys.append(k)
        \\        total += v
        \\    assert(keys.build() == "abc")
        \\    assert(total == 6)
        \\    assert((m.get("b") else 0) == 2)
        \\    assert(m.get("missing") == none)
        \\    assert((m.get("missing") else 99) == 99)
        \\    var vs = m.values()
        \\    assert(len(vs) == 3)
        \\    assert(vs[0] == 1 and vs[2] == 3)
        \\    assert(vs.contains(2))
        \\
    );
}

test "sequences: for index, element enumerates lists and rank-1 arrays" {
    try agreeOk(
        \\func main():
        \\    var xs = [10, 20, 30]
        \\    var sum_index: i64 = 0
        \\    var sum_value = 0
        \\    for i, x in xs:
        \\        sum_index += i
        \\        sum_value += x
        \\    assert(sum_index == 0 + 1 + 2)
        \\    assert(sum_value == 60)
        \\    var row = array[i64](4)
        \\    row.fill(5)
        \\    var seen: i64 = 0
        \\    for i, v in row:
        \\        seen += i
        \\        assert(v == 5)
        \\    assert(seen == 0 + 1 + 2 + 3)
        \\
    );
}

test "single-name for still binds keys for maps and elements for sequences" {
    try agreeOk(
        \\func main():
        \\    var m = map[i64, i64]()
        \\    m[7] = 70
        \\    m[8] = 80
        \\    var key_sum: i64 = 0
        \\    for k in m:
        \\        key_sum += k
        \\    assert(key_sum == 15)
        \\    var xs = [1, 2, 3]
        \\    var element_sum = 0
        \\    for x in xs:
        \\        element_sum += x
        \\    assert(element_sum == 6)
        \\
    );
}

test "arrays: fixed shape, zero-init, multi-dimensional indexing" {
    try agreeOk(
        \\func main():
        \\    var grid = array[i64](3, 4)
        \\    assert(grid.dim(0) == 3 and grid.dim(1) == 4)
        \\    assert(grid[2, 3] == 0)
        \\    grid[2, 3] = 7
        \\    assert(grid[2, 3] == 7)
        \\    var row = array[i64](5)
        \\    row.fill(9)
        \\    assert(row[0] == 9 and row[4] == 9)
        \\    assert(len(row) == 5)
        \\
    );
}

test "builders accumulate text" {
    try agreeOk(
        \\func main():
        \\    var b = builder()
        \\    b.append("he")
        \\    b.append("llo")
        \\    assert(b.build() == "hello")
        \\    assert(len(b) == 5)
        \\    b.clear()
        \\    assert(len(b) == 0)
        \\
    );
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

test "file-scope value constants fold and inline" {
    try agreeOk(
        \\const width = 80
        \\const midpoint = width // 2
        \\const name = "loom"
        \\const greeting = "hi " + name
        \\
        \\func main():
        \\    assert(width == 80)
        \\    assert(midpoint == 40)
        \\    assert(greeting == "hi loom")
        \\
    );
}

// ---------------------------------------------------------------------------
// Numeric builtins: abs / min / max / clamp
// ---------------------------------------------------------------------------

test "abs, min, max, clamp on i64" {
    try agreeOk(
        \\func main():
        \\    assert(abs(0 - 7) == 7)
        \\    assert(abs(7) == 7)
        \\    assert(abs(0) == 0)
        \\    assert(min(3, 8) == 3)
        \\    assert(max(3, 8) == 8)
        \\    assert(min(0 - 2, 0 - 5) == 0 - 5)
        \\    assert(clamp(5, 0, 10) == 5)
        \\    assert(clamp(0 - 3, 0, 10) == 0)
        \\    assert(clamp(42, 0, 10) == 10)
        \\
    );
}

test "abs, min, max, clamp on f64" {
    try agreeOk(
        \\func main():
        \\    assert(abs(0.0 - 2.5) == 2.5)
        \\    assert(min(1.5, 2.5) == 1.5)
        \\    assert(max(1.5, 2.5) == 2.5)
        \\    assert(clamp(0.5, 0.0, 1.0) == 0.5)
        \\    assert(clamp(0.0 - 1.0, 0.0, 1.0) == 0.0)
        \\    assert(clamp(9.0, 0.0, 1.0) == 1.0)
        \\
    );
}

test "floating builtins: sqrt, floor, ceil on exact and fractional inputs" {
    try agreeOk(
        \\func main():
        \\    assert(sqrt(16.0) == 4.0)
        \\    assert(sqrt(0.0) == 0.0)
        \\    assert(floor(2.999) == 2.0)
        \\    assert(floor(0.0 - 0.5) == 0.0 - 1.0)
        \\    assert(ceil(2.001) == 3.0)
        \\    assert(ceil(0.0 - 0.5) == 0.0)
        \\
    );
}

// ---------------------------------------------------------------------------
// Comparison operators across the ordered types
// ---------------------------------------------------------------------------

test "all six comparisons on i64" {
    try agreeOk(
        \\func main():
        \\    assert(1 < 2)
        \\    assert(not (2 < 2))
        \\    assert(2 <= 2)
        \\    assert(not (3 <= 2))
        \\    assert(3 > 2)
        \\    assert(not (2 > 2))
        \\    assert(2 >= 2)
        \\    assert(not (2 >= 3))
        \\    assert(2 == 2)
        \\    assert(2 != 3)
        \\
    );
}

test "all six comparisons on f64" {
    try agreeOk(
        \\func main():
        \\    assert(1.5 < 1.6)
        \\    assert(1.5 <= 1.5)
        \\    assert(1.6 > 1.5)
        \\    assert(1.5 >= 1.5)
        \\    assert(1.5 == 1.5)
        \\    assert(1.5 != 1.6)
        \\    assert(0.0 - 1.0 < 0.0)
        \\
    );
}

test "all six comparisons on str use lexicographic byte order" {
    try agreeOk(
        \\func main():
        \\    assert("a" < "b")
        \\    assert("abc" < "abd")
        \\    assert("ab" < "abc")
        \\    assert("abc" <= "abc")
        \\    assert("b" > "a")
        \\    assert("abc" >= "abc")
        \\    assert("" < "a")
        \\    assert("Z" < "a")
        \\    assert("abc" == "abc")
        \\    assert("abc" != "abcd")
        \\
    );
}

// ---------------------------------------------------------------------------
// Equality by type: bool, string, struct value, object identity
// ---------------------------------------------------------------------------

test "equality: bool truth table" {
    try agreeOk(
        \\func main():
        \\    assert(true == true)
        \\    assert(false == false)
        \\    assert(true != false)
        \\    assert((1 < 2) == (3 < 4))
        \\    assert((1 < 2) != (3 > 4))
        \\
    );
}

test "equality: lists compare by identity, not contents" {
    // Two independent lists with equal contents are not equal; a name
    // aliasing the same object is.
    try agreeOk(
        \\func main():
        \\    let a = [1, 2, 3]
        \\    let b = [1, 2, 3]
        \\    assert(a != b)
        \\    let same = a
        \\    assert(same == a)
        \\
    );
}

test "equality: structs compare field by field (value semantics)" {
    try agreeOk(
        \\struct Pair:
        \\    a: i64
        \\    b: i64
        \\
        \\func main():
        \\    let p = Pair(a = 1, b = 2)
        \\    let q = Pair(a = 1, b = 2)
        \\    let r = Pair(a = 1, b = 3)
        \\    assert(p == q)
        \\    assert(p != r)
        \\
    );
}

// ---------------------------------------------------------------------------
// Boolean operators: full truth tables and short-circuit on both sides
// ---------------------------------------------------------------------------

test "and / or / not full truth tables" {
    try agreeOk(
        \\func main():
        \\    assert((true and true) == true)
        \\    assert((true and false) == false)
        \\    assert((false and true) == false)
        \\    assert((false and false) == false)
        \\    assert((true or true) == true)
        \\    assert((true or false) == true)
        \\    assert((false or true) == true)
        \\    assert((false or false) == false)
        \\    assert((not true) == false)
        \\    assert((not false) == true)
        \\
    );
}

// ---------------------------------------------------------------------------
// Control flow: for-each shapes, empty ranges, continue, deep recursion
// ---------------------------------------------------------------------------

test "for-range over a reversed interval iterates zero times" {
    try agreeOk(
        \\func main():
        \\    var count = 0
        \\    for i in range(5, 2):
        \\        count = count + 1
        \\    assert(count == 0)
        \\    var count2 = 0
        \\    for i in range(0, 0):
        \\        count2 = count2 + 1
        \\    assert(count2 == 0)
        \\
    );
}

test "for-each over a list sums its elements in order" {
    try agreeOk(
        \\func main():
        \\    let xs = [4, 5, 6]
        \\    var out = builder()
        \\    for x in xs:
        \\        out.append(str(x))
        \\    assert(out.build() == "456")
        \\
    );
}

test "for-each over a rank-1 array visits every slot" {
    try agreeOk(
        \\func main():
        \\    var row = array[i64](4)
        \\    row[0] = 1
        \\    row[1] = 2
        \\    row[2] = 3
        \\    row[3] = 4
        \\    var total: i64 = 0
        \\    for v in row:
        \\        total = total + v
        \\    assert(total == 10)
        \\
    );
}

test "for-each over map keys walks insertion order" {
    try agreeOk(
        \\func main():
        \\    var m = map[str, i64]()
        \\    m["x"] = 1
        \\    m["y"] = 2
        \\    m["z"] = 3
        \\    var joined = builder()
        \\    for k in m.keys():
        \\        joined.append(k)
        \\    assert(joined.build() == "xyz")
        \\
    );
}

test "continue in a for-loop skips the rest of the body" {
    try agreeOk(
        \\func main():
        \\    var total: i64 = 0
        \\    for i in range(0, 10):
        \\        if i % 2 == 0:
        \\            continue
        \\        total = total + i
        \\    assert(total == 1 + 3 + 5 + 7 + 9)
        \\
    );
}

test "continue in a nested loop affects only the inner loop" {
    try agreeOk(
        \\func main():
        \\    var hits = 0
        \\    for i in range(0, 3):
        \\        for j in range(0, 3):
        \\            if j == 1:
        \\                continue
        \\            hits = hits + 1
        \\    assert(hits == 6)
        \\
    );
}

test "a nested try reconciles a fallible for-in temporary before propagating" {
    try agree.ok(
        \\enum Kind:
        \\    first
        \\    second
        \\    third
        \\
        \\func kinds() -> list[Kind]!:
        \\    var values: list[Kind] = [Kind.first, Kind.second, Kind.third]
        \\    return values
        \\
        \\func score(kind: Kind) -> i64!:
        \\    if kind == Kind.second:
        \\        error("stop")
        \\    return 1
        \\
        \\func run() -> i64!:
        \\    var total: i64 = 0
        \\    for kind in try kinds():
        \\        match kind:
        \\            first:
        \\                total += try score(kind)
        \\            second:
        \\                total += try score(kind)
        \\            third:
        \\                total += try score(kind)
        \\    return total
        \\
        \\func main():
        \\    var stopped = false
        \\    run() catch reason:
        \\        assert(reason == "stop")
        \\        stopped = true
        \\    assert(stopped)
        \\
    );
}

test "a nested catch reconciles a fallible for-in temporary on both arms" {
    try agree.ok(
        \\enum Kind:
        \\    first
        \\    second
        \\    third
        \\
        \\func kinds() -> list[Kind]!:
        \\    var values: list[Kind] = [Kind.first, Kind.second, Kind.third]
        \\    return values
        \\
        \\func score(kind: Kind) -> i64!:
        \\    if kind == Kind.second:
        \\        error("stop")
        \\    return 1
        \\
        \\func run() -> i64!:
        \\    var total: i64 = 0
        \\    for kind in try kinds():
        \\        match kind:
        \\            first:
        \\                total += score(kind) catch 10
        \\            second:
        \\                total += score(kind) catch 10
        \\            third:
        \\                total += score(kind) catch 10
        \\    return total
        \\
        \\func main() -> !:
        \\    assert((try run()) == 12)
        \\
    );
}

test "continue in match preserves a fallible for-in iterable" {
    try agree.ok(
        \\enum Kind:
        \\    first
        \\    second
        \\    third
        \\
        \\func kinds() -> list[Kind]!:
        \\    var values: list[Kind] = [Kind.first, Kind.second, Kind.third]
        \\    return values
        \\
        \\func run() -> i64!:
        \\    var total: i64 = 0
        \\    for kind in try kinds():
        \\        match kind:
        \\            first:
        \\                continue
        \\            second:
        \\                total += 2
        \\            third:
        \\                total += 3
        \\    return total
        \\
        \\func main() -> !:
        \\    assert((try run()) == 5)
        \\
    );
}

test "break in match releases a fallible for-in iterable at the loop exit" {
    try agree.ok(
        \\enum Kind:
        \\    first
        \\    second
        \\    third
        \\
        \\func kinds() -> list[Kind]!:
        \\    var values: list[Kind] = [Kind.first, Kind.second, Kind.third]
        \\    return values
        \\
        \\func run() -> i64!:
        \\    var total: i64 = 0
        \\    for kind in try kinds():
        \\        match kind:
        \\            first:
        \\                total += 1
        \\            second:
        \\                break
        \\            third:
        \\                total += 100
        \\    return total
        \\
        \\func main() -> !:
        \\    assert((try run()) == 1)
        \\
    );
}

test "return in match releases a fallible for-in iterable immediately" {
    try agree.ok(
        \\enum Kind:
        \\    first
        \\    second
        \\    third
        \\
        \\func kinds() -> list[Kind]!:
        \\    var values: list[Kind] = [Kind.first, Kind.second, Kind.third]
        \\    return values
        \\
        \\func run() -> i64!:
        \\    var total: i64 = 0
        \\    for kind in try kinds():
        \\        match kind:
        \\            first:
        \\                total += 1
        \\            second:
        \\                return total + 10
        \\            third:
        \\                total += 100
        \\    return total
        \\
        \\func main() -> !:
        \\    assert((try run()) == 11)
        \\
    );
}

test "the explicit frame stack survives a deep iterative-recursive sum" {
    try agreeOk(
        \\func sum_to(n: i64) -> i64:
        \\    if n == 0:
        \\        return 0
        \\    return n + sum_to(n - 1)
        \\
        \\func main():
        \\    assert(sum_to(4000) == 8002000)
        \\
    );
}

test "strings: slicing corners — empty, full, and open ends" {
    try agreeOk(
        \\func main():
        \\    let s = "abcde"
        \\    assert(s[0:0] == "")
        \\    assert(s[2:2] == "")
        \\    assert(s[0:5] == "abcde")
        \\    assert(s[:] == "abcde")
        \\    assert(s[:3] == "abc")
        \\    assert(s[3:] == "de")
        \\    assert(s[5:5] == "")
        \\
    );
}

test "strings: byte_at reads raw UTF-8 bytes of a multibyte string" {
    // λ is one scalar and two bytes (CE BB); byte_at is explicitly the
    // raw encoding view.
    try agreeOk(
        \\func main():
        \\    let s = "λ"
        \\    assert(len(s) == 1)
        \\    assert(len(bytes(s)) == 2)
        \\    assert(s.byte_at(0) == 206)
        \\    assert(s.byte_at(1) == 187)
        \\    let mix = "aλb"
        \\    assert(len(mix) == 3)
        \\    assert(len(bytes(mix)) == 4)
        \\    assert(mix.byte_at(0) == 97)
        \\    assert(mix[0:1] == "a")
        \\    assert(mix[1:2] == "λ")
        \\    assert(mix[2:3] == "b")
        \\
    );
}

// ---------------------------------------------------------------------------
// Conversions in depth
// ---------------------------------------------------------------------------

test "str renders every scalar, and a builder hands over its own" {
    try agreeOk(
        \\func main():
        \\    assert(str(0) == "0")
        \\    assert(str(1000000) == "1000000")
        \\    assert(str(1.5) == "1.5")
        \\    assert(str(3.0) == "3")
        \\    assert(str(true) == "true")
        \\    assert(str("already") == "already")
        \\    var b = builder()
        \\    b.append("bld")
        \\    assert(b.build() == "bld")
        \\
    );
}

test "parse_i64 and parse_f64 accept signs and round-trip str" {
    try agreeOk(
        \\func main():
        \\    assert((parse_i64("0") else 1) == 0)
        \\    assert((parse_i64("-42") else 0) == 0 - 42)
        \\    assert((parse_i64("+7") else 0) == 7)
        \\    assert((parse_f64("3.25") else 0.0) == 3.25)
        \\    assert((parse_f64("-0.5") else 0.0) == 0.0 - 0.5)
        \\    assert((parse_i64(str(98765)) else 0) == 98765)
        \\
    );
}

test "parse_i64 and parse_f64 answer none rather than trapping" {
    try agreeOk(
        \\func main():
        \\    assert(parse_i64("not a number") == none)
        \\    assert(parse_i64("4 2") == none)
        \\    assert(parse_i64("") == none)
        \\    assert(parse_f64("abc") == none)
        \\    assert(parse_f64("inf") == none)
        \\    assert(parse_f64("nan") == none)
        \\    assert(parse_i64("7") != none)
        \\    assert((parse_i64("nope") else 0 - 1) == 0 - 1)
        \\    assert((parse_f64("nope") else 2.5) == 2.5)
        \\
    );
}

test "char conversions round-trip across ASCII and multibyte codepoints" {
    try agreeOk(
        \\func main():
        \\    assert(str(char(97)) == "a")
        \\    assert(u32('a') == u32(97))
        \\    assert(u32(char(0)) == u32(0))
        \\    assert(str(char(955)) == "λ")
        \\    assert(u32('λ') == u32(955))
        \\    assert(str(char(128578)) == "🙂")
        \\    assert(u32('🙂') == u32(128578))
        \\    assert(u32(char(128578)) == u32(128578))
        \\
    );
}

// ---------------------------------------------------------------------------
// Lists: methods, slicing independence, nesting, structs
// ---------------------------------------------------------------------------

test "lists: sort orders i64, f64, and str in place" {
    try agreeOk(
        \\func main():
        \\    var ints = [3, 1, 2]
        \\    ints.sort()
        \\    assert(ints[0] == 1 and ints[1] == 2 and ints[2] == 3)
        \\    var floats = [2.5, 0.5, 1.5]
        \\    floats.sort()
        \\    assert(floats[0] == 0.5 and floats[2] == 2.5)
        \\    var words = ["cherry", "apple", "banana"]
        \\    words.sort()
        \\    assert(words[0] == "apple" and words[2] == "cherry")
        \\
    );
}

test "lists: sort is stable — equal elements keep their order" {
    // -0.0 and 0.0 compare equal and print differently, so the order
    // a sort leaves them in is observable from a Luce program.  That
    // makes stability part of the language, not an implementation
    // detail: this test fails outright under an unstable sort.
    try agreeOk(
        \\func main():
        \\    var xs: list[f64] = []
        \\    var i = 0
        \\    while i < 40:
        \\        xs.append(1.0)
        \\        xs.append(-0.0)
        \\        xs.append(0.0)
        \\        i += 1
        \\    xs.sort()
        \\    i = 0
        \\    while i < 40:
        \\        assert(str(xs[i * 2]) == "-0")
        \\        assert(str(xs[i * 2 + 1]) == "0")
        \\        i += 1
        \\    assert(xs[80] == 1.0)
        \\
    );
}

test "lists: reverse, find, contains, clear" {
    try agreeOk(
        \\func main():
        \\    var xs = [1, 2, 3, 4]
        \\    xs.reverse()
        \\    assert(xs[0] == 4 and xs[3] == 1)
        \\    assert((xs.find(3) else -1) == 1)
        \\    assert(xs.find(99) == none)
        \\    assert(xs.contains(2))
        \\    assert(not xs.contains(99))
        \\    xs.clear()
        \\    assert(len(xs) == 0)
        \\
    );
}

test "lists: a slice is an independent copy" {
    try agreeOk(
        \\func main():
        \\    var xs = [1, 2, 3, 4, 5]
        \\    var mid = xs[1:4]
        \\    assert(len(mid) == 3)
        \\    assert(mid[0] == 2 and mid[2] == 4)
        \\    mid[0] = 99
        \\    assert(xs[1] == 2)
        \\    xs[2] = 88
        \\    assert(mid[1] == 3)
        \\    assert(len(xs[:]) == 5)
        \\    assert(len(xs[2:2]) == 0)
        \\
    );
}

test "lists: value structs stored by copy are independent" {
    // append copies the value struct; later mutating the source or
    // replacing one slot leaves the other stored copies untouched.
    // (Assignment targets are a single field or a single index, so a
    // slot is replaced whole with cells[i] = ..., not cells[i].v = ...)
    try agreeOk(
        \\struct Cell:
        \\    v: i64
        \\
        \\func main():
        \\    var cells = list[Cell]()
        \\    var c = Cell(v = 1)
        \\    cells.append(c)
        \\    cells.append(c)
        \\    c.v = 99
        \\    assert(cells[0].v == 1 and cells[1].v == 1)
        \\    cells[0] = Cell(v = 5)
        \\    assert(cells[0].v == 5 and cells[1].v == 1)
        \\    assert(c.v == 99)
        \\
    );
}

// ---------------------------------------------------------------------------
// Maps: key types, removal, clear
// ---------------------------------------------------------------------------

test "maps: i64 keys, lookup, has, and len" {
    try agreeOk(
        \\func main():
        \\    var m = map[i64, str]()
        \\    m[1] = "one"
        \\    m[2] = "two"
        \\    m[10] = "ten"
        \\    assert(len(m) == 3)
        \\    assert(m[10] == "ten")
        \\    assert(m.has(1))
        \\    assert(not m.has(3))
        \\    m[1] = "uno"
        \\    assert(m[1] == "uno")
        \\    assert(len(m) == 3)
        \\
    );
}

test "maps: removing an absent key is a no-op; clear empties" {
    try agreeOk(
        \\func main():
        \\    var m = map[str, i64]()
        \\    m["a"] = 1
        \\    m["b"] = 2
        \\    m.remove("ghost")
        \\    assert(len(m) == 2)
        \\    m.remove("a")
        \\    assert(len(m) == 1 and not m.has("a"))
        \\    m.clear()
        \\    assert(len(m) == 0)
        \\    m["c"] = 3
        \\    assert(m["c"] == 3)
        \\
    );
}

test "maps: hundreds of keys keep insertion order and every lookup hits" {
    // Small maps say nothing about the hash index: this one grows
    // past several rebuilds, so keys collide, probe sequences run
    // long, and removal renumbers every entry behind the one it took
    // out.  Insertion order is a promise of the language (iteration,
    // keys()), and it has to survive all of that.
    try agreeOk(
        \\func main():
        \\    var m = map[str, i64]()
        \\    var i = 0
        \\    while i < 300:
        \\        m["k" + str(i)] = i
        \\        i += 1
        \\    assert(len(m) == 300)
        \\    var seen = 0
        \\    for key, held in m:
        \\        assert(key == "k" + str(held))
        \\        assert(held == seen)
        \\        seen += 1
        \\    assert(seen == 300)
        \\    i = 0
        \\    while i < 300:
        \\        assert(m["k" + str(i)] == i)
        \\        assert(m.has("k" + str(i)))
        \\        i += 1
        \\    i = 0
        \\    while i < 300:
        \\        if i % 2 == 0:
        \\            m.remove("k" + str(i))
        \\        i += 1
        \\    assert(len(m) == 150)
        \\    var next = 1
        \\    for key in m:
        \\        assert(key == "k" + str(next))
        \\        next += 2
        \\    assert((m.get("k5") else 0 - 1) == 5)
        \\    assert(m.get("k4") == none)
        \\
    );
}

test "maps: i64 keys survive growth, negatives, and the extremes" {
    try agreeOk(
        \\func main():
        \\    var m = map[i64, i64]()
        \\    var i = 0 - 200
        \\    while i < 200:
        \\        m[i * 3] = i
        \\        i += 1
        \\    assert(len(m) == 400)
        \\    i = 0 - 200
        \\    while i < 200:
        \\        assert(m[i * 3] == i)
        \\        i += 1
        \\    assert(not m.has(1))
        \\    m[9223372036854775807] = 1
        \\    m[0 - 9223372036854775807 - 1] = 2
        \\    assert(m[9223372036854775807] == 1)
        \\    assert(m[0 - 9223372036854775807 - 1] == 2)
        \\
    );
}

// ---------------------------------------------------------------------------
// Arrays: ranks 1..4, dims, fill, rank-1 methods
// ---------------------------------------------------------------------------

test "arrays: ranks one through four report their dims and zero-init" {
    try agreeOk(
        \\func main():
        \\    var a1 = array[i64](5)
        \\    assert(a1.dim(0) == 5 and a1[4] == 0)
        \\    var a2 = array[i64](2, 3)
        \\    assert(a2.dim(0) == 2 and a2.dim(1) == 3)
        \\    assert(a2[1, 2] == 0)
        \\    var a3 = array[i64](2, 2, 2)
        \\    assert(a3.dim(2) == 2 and a3[1, 1, 1] == 0)
        \\    a3[1, 1, 1] = 7
        \\    assert(a3[1, 1, 1] == 7 and a3[0, 0, 0] == 0)
        \\    var a4 = array[i64](2, 2, 2, 2)
        \\    assert(a4.dim(3) == 2 and a4[1, 1, 1, 1] == 0)
        \\    a4[1, 1, 1, 1] = 9
        \\    assert(a4[1, 1, 1, 1] == 9)
        \\
    );
}

test "arrays: fill sets every slot; len is the first dimension" {
    try agreeOk(
        \\func main():
        \\    var row = array[f64](4)
        \\    row.fill(1.5)
        \\    assert(row[0] == 1.5 and row[3] == 1.5)
        \\    assert(len(row) == 4)
        \\    var grid = array[i64](3, 5)
        \\    assert(len(grid) == 3)
        \\
    );
}

test "arrays: rank-1 sort, reverse, find, contains" {
    try agreeOk(
        \\func main():
        \\    var row = array[i64](4)
        \\    row[0] = 3
        \\    row[1] = 1
        \\    row[2] = 4
        \\    row[3] = 2
        \\    row.sort()
        \\    assert(row[0] == 1 and row[3] == 4)
        \\    assert((row.find(4) else -1) == 3)
        \\    assert(row.contains(2))
        \\    assert(not row.contains(99))
        \\    row.reverse()
        \\    assert(row[0] == 4 and row[3] == 1)
        \\
    );
}

// ---------------------------------------------------------------------------
// Structs: functional update independence, nesting, in collections
// ---------------------------------------------------------------------------

test "structs: assigning a copy leaves the source untouched for value fields" {
    try agreeOk(
        \\struct Point:
        \\    x: i64
        \\    y: i64
        \\
        \\func main():
        \\    var a = Point(x = 1, y = 2)
        \\    var b = a
        \\    b.x = 100
        \\    b.y = 200
        \\    assert(a.x == 1 and a.y == 2)
        \\    assert(b.x == 100 and b.y == 200)
        \\
    );
}

test "structs: nested value structs copy deeply" {
    // Copying a struct duplicates its nested value struct; replacing
    // the inner field on the copy does not reach the original.  (A
    // nested field cannot be an assignment target — p.inner.n = ... is
    // rejected — so the whole inner field is replaced instead.)
    try agreeOk(
        \\struct Inner:
        \\    n: i64
        \\
        \\struct Outer:
        \\    inner: Inner
        \\    tag: i64
        \\
        \\func main():
        \\    var o = Outer(inner = Inner(n = 1), tag = 0)
        \\    var p = o
        \\    p.inner = Inner(n = 99)
        \\    p.tag = 7
        \\    assert(o.inner.n == 1)
        \\    assert(o.tag == 0)
        \\    assert(p.inner.n == 99 and p.tag == 7)
        \\
    );
}

test "structs: namespaced functions can recurse and call peers" {
    try agreeOk(
        \\struct Math:
        \\    dummy: i64
        \\
        \\    static func square(n: i64) -> i64:
        \\        return n * n
        \\
        \\    static func hypot_sq(a: i64, b: i64) -> i64:
        \\        return Math.square(a) + Math.square(b)
        \\
        \\func main():
        \\    assert(Math.square(5) == 25)
        \\    assert(Math.hypot_sq(3, 4) == 25)
        \\
    );
}

// ---------------------------------------------------------------------------
// Ownership: behavioral positives (transfer, deep copy, drop, late slots)
// ---------------------------------------------------------------------------

test "ownership: give transfers an object into a new owner" {
    try agreeOk(
        \\func main():
        \\    var original = [1, 2, 3]
        \\    var moved = original
        \\    moved.append(4)
        \\    assert(len(moved) == 4)
        \\    assert(moved[3] == 4)
        \\
    );
}

test "ownership: reassigning an owning var frees the old object with no leak" {
    try agreeOk(
        \\func main():
        \\    var b = builder()
        \\    b.append("first")
        \\    b = builder()
        \\    b.append("second")
        \\    assert(b.build() == "second")
        \\
    );
}

test "ownership: a late-declared object slot can be filled and used" {
    try agreeOk(
        \\func main():
        \\    var xs: list[i64]
        \\    xs = [7, 8, 9]
        \\    assert(len(xs) == 3)
        \\    xs.append(10)
        \\    assert(xs[3] == 10)
        \\
    );
}

test "ownership: return moves an object out of a function" {
    try agreeOk(
        \\func make() -> list[i64]:
        \\    var xs = list[i64]()
        \\    xs.append(1)
        \\    xs.append(2)
        \\    return xs
        \\
        \\func main():
        \\    var got = make()
        \\    assert(len(got) == 2)
        \\    assert(got[0] == 1 and got[1] == 2)
        \\
    );
}

test "ownership: a borrowed parameter is read without transfer" {
    try agreeOk(
        \\func total(xs: list[i64]) -> i64:
        \\    var sum: i64 = 0
        \\    for x in xs:
        \\        sum = sum + x
        \\    return sum
        \\
        \\func main():
        \\    var xs: list[i64] = [1, 2, 3, 4]
        \\    assert(total(xs) == 10)
        \\    assert(len(xs) == 4)
        \\    assert(total(xs) == 10)
        \\
    );
}

// ---------------------------------------------------------------------------
// Late declarations and zero values
// ---------------------------------------------------------------------------

test "late var declarations hold the zero value of their type" {
    try agreeOk(
        \\struct Vec3:
        \\    x: i64
        \\    y: i64
        \\    z: i64
        \\
        \\func main():
        \\    var n: i64
        \\    assert(n == 0)
        \\    var f: f64
        \\    assert(f == 0.0)
        \\    var flag: bool
        \\    assert(not flag)
        \\    var s: str
        \\    assert(s == "")
        \\    assert(len(s) == 0)
        \\    var v: Vec3
        \\    assert(v.x == 0 and v.y == 0 and v.z == 0)
        \\
    );
}

test "a late var can be assigned after a branch decides its value" {
    try agreeOk(
        \\func pick(flag: bool) -> i64:
        \\    var out: i64
        \\    if flag:
        \\        out = 10
        \\    else:
        \\        out = 20
        \\    return out
        \\
        \\func main():
        \\    assert(pick(true) == 10)
        \\    assert(pick(false) == 20)
        \\
    );
}

// ---------------------------------------------------------------------------
// Constants: every scalar type, cross-references, use inside functions
// ---------------------------------------------------------------------------

test "constants of every scalar type fold and inline" {
    try agreeOk(
        \\const limit = 3 * 4
        \\const ratio = 1.0 / 4.0
        \\const enabled = true and not false
        \\const prefix = "id_"
        \\
        \\func label(n: i64) -> str:
        \\    return prefix + str(n)
        \\
        \\func main():
        \\    assert(limit == 12)
        \\    assert(ratio == 0.25)
        \\    assert(enabled)
        \\    assert(label(7) == "id_7")
        \\
    );
}

test "constants reference earlier constants" {
    try agreeOk(
        \\const base = 10
        \\const doubled = base * 2
        \\const quadrupled = doubled * 2
        \\const name = "core"
        \\const full = name + "!"
        \\
        \\func main():
        \\    assert(doubled == 20)
        \\    assert(quadrupled == 40)
        \\    assert(full == "core!")
        \\
    );
}

// ---------------------------------------------------------------------------
// Absence: T?, none, narrowing, else (docs/FAILURE.md)
// ---------------------------------------------------------------------------

test "a T? holds either a value or none, and says which" {
    try agreeOk(
        \\func passthrough(n: i64?) -> i64?:
        \\    return n
        \\
        \\func text(t: str?) -> str?:
        \\    return t
        \\
        \\func main():
        \\    var n: i64? = none
        \\    assert(n == none)
        \\    assert(not (n != none))
        \\    n = 7
        \\    # Through a call the narrowing is gone and the question is
        \\    # a real one again.
        \\    assert(passthrough(n) != none)
        \\    assert(not (passthrough(n) == none))
        \\    var t: str? = "hi"
        \\    assert(text(t) != none)
        \\    t = none
        \\    assert(t == none)
        \\
    );
}

test "narrowing: a tested name is its payload inside the branch, and both branches see it" {
    try agreeOk(
        \\func main():
        \\    let n = parse_i64("41")
        \\    var seen: i64 = 0
        \\    if n != none:
        \\        seen = n + 1
        \\    else:
        \\        seen = 0 - 1
        \\    assert(seen == 42)
        \\
        \\    let bad = parse_i64("x")
        \\    var other: i64 = 0
        \\    if bad == none:
        \\        other = 5
        \\    else:
        \\        other = bad * 2
        \\    assert(other == 5)
        \\
    );
}

test "narrowing: an early-return guard narrows the rest of the block" {
    try agreeOk(
        \\func doubled(text: str) -> i64:
        \\    let n = parse_i64(text)
        \\    if n == none:
        \\        return 0 - 1
        \\    return n * 2
        \\
        \\func main():
        \\    assert(doubled("21") == 42)
        \\    assert(doubled("nope") == 0 - 1)
        \\
    );
}

test "narrowing: continue and break guards narrow what follows them" {
    try agreeOk(
        \\func main():
        \\    let inputs = ["1", "x", "3"]
        \\    var total: i64 = 0
        \\    for text in inputs:
        \\        let n = parse_i64(text)
        \\        if n == none:
        \\            continue
        \\        total = total + n
        \\    assert(total == 4)
        \\
        \\    var index = 0
        \\    var first: i64 = 0
        \\    while index < len(inputs):
        \\        let n = parse_i64(inputs[index])
        \\        index = index + 1
        \\        if n == none:
        \\            break
        \\        first = first + n
        \\    assert(first == 1)
        \\
    );
}

test "narrowing: and carries the test into the rest of the condition" {
    try agreeOk(
        \\func main():
        \\    let n = parse_i64("5")
        \\    var hit = false
        \\    if n != none and n > 3:
        \\        hit = true
        \\    assert(hit)
        \\
        \\    let bad = parse_i64("x")
        \\    var missed = false
        \\    if bad != none and bad > 3:
        \\        missed = true
        \\    assert(not missed)
        \\
        \\    # `or` narrows on its false side, which is the dual.
        \\    var reached = false
        \\    if bad == none or bad > 3:
        \\        reached = true
        \\    assert(reached)
        \\
    );
}

test "narrowing: an assignment of a plain value proves the name present" {
    try agreeOk(
        \\func main():
        \\    var n: i64? = none
        \\    n = 3
        \\    assert(n * 2 == 6)
        \\    var xs: list[i64]? = none
        \\    xs = list[i64]()
        \\    xs.append(4)
        \\    assert(len(xs) == 1)
        \\
    );
}

test "narrowing: a while condition narrows its body" {
    try agreeOk(
        \\func main():
        \\    var countdown: i64? = 3
        \\    var steps = 0
        \\    while countdown != none:
        \\        steps = steps + 1
        \\        if countdown == 1:
        \\            countdown = none
        \\        else:
        \\            countdown = countdown - 1
        \\    assert(steps == 3)
        \\
    );
}

test "else supplies the fallback, lazily, and chains to the right" {
    try agreeOk(
        \\func main():
        \\    assert((parse_i64("8") else 0) == 8)
        \\    assert((parse_i64("x") else 0) == 0)
        \\    # right-associative: the first that is there wins.
        \\    assert((parse_i64("x") else parse_i64("9") else 0) == 9)
        \\    assert((parse_i64("x") else parse_i64("y") else 3) == 3)
        \\    # `else` binds tighter than comparison and looser than +.
        \\    assert((parse_i64("x") else 2 + 3) == 5)
        \\    assert(((parse_i64("x") else 1) == 1) == true)
        \\
    );
}

test "else runs its fallback only when the value is absent" {
    try agreeOk(
        \\func note(log: builder, mark: str) -> i64:
        \\    log.append(mark)
        \\    return 0
        \\
        \\func main():
        \\    let log = builder()
        \\    assert((parse_i64("1") else note(log, "a")) == 1)
        \\    assert((parse_i64("x") else note(log, "b")) == 0)
        \\    assert(log.build() == "b")
        \\
    );
}

test "x else trap is the assert-unwrap" {
    try agreeOk(
        \\func main():
        \\    let n = parse_i64("12") else trap("unreachable")
        \\    assert(n == 12)
        \\
    );
    try agreeTrap(
        \\func main():
        \\    var text = "not a number"
        \\    let n = parse_i64(text) else trap("bad input")
        \\    assert(n == 0)
        \\
    , .explicit_trap);
}

test "an optional crosses a call, a return, and a struct field" {
    try agreeOk(
        \\struct Setting:
        \\    name: str
        \\    limit: i64?
        \\
        \\func describe(limit: i64?) -> str:
        \\    if limit == none:
        \\        return "unlimited"
        \\    return str(limit)
        \\
        \\func lookup(found: bool) -> i64?:
        \\    if found:
        \\        return 4
        \\    return none
        \\
        \\func main():
        \\    assert(describe(none) == "unlimited")
        \\    assert(describe(9) == "9")
        \\    assert(describe(lookup(true)) == "4")
        \\    assert(describe(lookup(false)) == "unlimited")
        \\    let open = Setting(name = "open", limit = none)
        \\    let capped = Setting(name = "capped", limit = 10)
        \\    assert(open.limit == none)
        \\    assert(describe(capped.limit) == "10")
        \\
    );
}

test "a value struct may hold an optional of itself, and walking it terminates" {
    // `Node?` gives a struct a finite shape where `Node` could not:
    // the recursion stops at absence rather than at a layout, so a
    // linked list of value structs falls out with no new machinery
    // and no reference counting anywhere.
    try agreeOk(
        \\struct Node:
        \\    value: i64
        \\    next: Node?
        \\
        \\func total(head: Node?) -> i64:
        \\    var sum: i64 = 0
        \\    var walk = head
        \\    while walk != none:
        \\        sum = sum + walk.value
        \\        walk = walk.next
        \\    return sum
        \\
        \\func main():
        \\    let three = Node(value = 3, next = none)
        \\    let two = Node(value = 2, next = three)
        \\    let one = Node(value = 1, next = two)
        \\    assert(total(one) == 6)
        \\    assert(total(none) == 0)
        \\
    );
}

test "a compound assignment combines at the payload and stays present" {
    try agreeOk(
        \\func main():
        \\    var n: i64? = none
        \\    n = 10
        \\    n += 5
        \\    n *= 2
        \\    assert(n == 30)
        \\    var s: str? = "a"
        \\    s += "b"
        \\    assert(s == "ab")
        \\
    );
}

test "absence survives a round trip through a struct field and a var" {
    try agreeOk(
        \\struct Slot:
        \\    held: str?
        \\
        \\func main():
        \\    var slot = Slot(held = none)
        \\    assert(slot.held == none)
        \\    slot.held = "there"
        \\    assert(slot.held != none)
        \\    assert((slot.held else "") == "there")
        \\    slot.held = none
        \\    assert(slot.held == none)
        \\
    );
}

// ---------------------------------------------------------------------------
// Runtime traps reachable through ordinary core expressions.  Host,
// constant-materialization and defense-only traps have their proofs in
// the specs or runtime seams that can actually produce them.
// ---------------------------------------------------------------------------

// Checked arithmetic uses one trap code at every width (docs/TYPES.md
// §4). These cases pin representative 64- and 32-bit boundaries; the
// exhaustive explicit-width suite below covers the complete roster.

test "trap: integer overflow on addition" {
    try agreeTrap(
        \\func main():
        \\    var x: i64 = 9223372036854775807
        \\    x = x + 1
        \\
    , .integer_overflow);
    try agreeTrap(
        \\func main():
        \\    var x: i32 = 2147483647
        \\    x = x + 1
        \\
    , .integer_overflow);
}

test "trap: integer overflow negating the minimum" {
    try agreeTrap(
        \\func main():
        \\    var n: i64 = 0 - 9223372036854775807
        \\    n = n - 1
        \\    let bad = 0 - n
        \\
    , .integer_overflow);
    try agreeTrap(
        \\func main():
        \\    var n: i32 = 0 - 2147483647
        \\    n = n - 1
        \\    let bad = 0 - n
        \\
    , .integer_overflow);
}

test "trap: integer overflow taking abs of the minimum" {
    try agreeTrap(
        \\func main():
        \\    var n: i64 = 0 - 9223372036854775807
        \\    n = n - 1
        \\    let bad = abs(n)
        \\
    , .integer_overflow);
    try agreeTrap(
        \\func main():
        \\    var n: i32 = 0 - 2147483647
        \\    n = n - 1
        \\    let bad = abs(n)
        \\
    , .integer_overflow);
}

test "trap: integer overflow multiplying, at the width that reaches it first" {
    // 46,341 squared is past 2^31 — the boundary docs/TYPES.md §4
    // says out loud that ordinary code reaches, and the reason `i32`
    // is a type you ask for rather than the one arithmetic defaults
    // to when it has a `i64` in it.
    try agreeTrap(
        \\func main():
        \\    var n: i32 = 46341
        \\    let bad = n * n
        \\
    , .integer_overflow);
    // And the same program one rung up, where it simply computes.
    try agreeOk(
        \\func main():
        \\    var n: i64 = 46341
        \\    assert(n * n == 2147488281)
        \\
    );
}

test "trap: // by zero" {
    try agreeTrap(
        \\func main():
        \\    var z = 0
        \\    let bad = 1 // z
        \\
    , .divide_by_zero);
}

test "trap: % by zero" {
    try agreeTrap(
        \\func main():
        \\    var z = 0
        \\    let bad = 1 % z
        \\
    , .divide_by_zero);
}

test "trap: floating-to-integer conversion out of range" {
    try agreeTrap(
        \\func main():
        \\    var big = 1.0
        \\    while big < 1.0e30:
        \\        big = big * 10.0
        \\    let bad = i64(big)
        \\
    , .conversion_range);
}

test "trap: a failed assertion" {
    try agreeTrap(
        \\func main():
        \\    var ok = false
        \\    assert(ok)
        \\
    , .assertion_failed);
}

test "trap: an explicit trap call" {
    try agreeTrap(
        \\func main():
        \\    trap("stop here")
        \\
    , .explicit_trap);
}

test "a built trap message survives the frame that built it" {
    // GitHub #28. The words are a str built at the trap site, so
    // they live in the trapping frame — short enough to sit *inside*
    // the value, which on the compiled path is an `alloca`.  The trap
    // channel used to keep that borrow, and the report is only read
    // once the whole run has stopped, so what it printed was whatever
    // the abandoned frame had been overwritten with.  The successful
    // call in front is what guarantees there is overwriting: the same
    // program without it read the same dead slot and found it
    // untouched.
    try agree.trapSays(
        \\func want(text: str) -> i64:
        \\    return parse_i64(text) else trap("not a number: " + text)
        \\
        \\func main():
        \\    print(str(want("41")))
        \\    print(str(want("oops")))
        \\
    , .explicit_trap, "not a number: oops");
}

test "a built trap message survives at every length" {
    // The short one lives in the value; the long one is an allocation
    // the trap unwinds past.  Both are the frame's, and both have to
    // reach the report — one door, two forms of storage behind it.
    try agree.trapSays(
        \\func stop(name: str):
        \\    trap("stopped by " + name)
        \\
        \\func main():
        \\    stop("a name long enough that its message cannot live inside a value")
        \\
    , .explicit_trap, "stopped by a name long enough that its message cannot live inside a value");
}

test "trap: list index out of bounds" {
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    let bad = xs[3]
        \\
    , .index_bounds);
}

// Every bounded container operation, at the last index it accepts and
// the first it refuses.  A bound tested from one side only is a bound
// whose comparison can be loosened by one without any test noticing,
// and the loose side of `insert` is a write past the end of a list.

test "bounds: a list accepts its last index and refuses the one past it" {
    try agreeOk(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var last = 2
        \\    assert(xs[last] == 3)
        \\    xs[last] = 30
        \\    assert(xs[2] == 30)
        \\    xs.remove(last)
        \\    assert(len(xs) == 2)
        \\
    );
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var past = 3
        \\    xs[past] = 0
        \\
    , .index_bounds);
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var below = -1
        \\    let bad = xs[below]
        \\
    , .index_bounds);
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var past = 3
        \\    xs.remove(past)
        \\
    , .index_bounds);
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var below = -1
        \\    xs.remove(below)
        \\
    , .index_bounds);
}

test "bounds: insert accepts the length itself, and nothing beyond it" {
    // `xs.insert(len(xs), v)` is the append form and must keep
    // working: this is the one list bound that is not the read bound,
    // and reading it as one loses a legal call rather than admitting
    // an illegal one.
    try agreeOk(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var at = len(xs)
        \\    xs.insert(at, 4)
        \\    assert(len(xs) == 4)
        \\    assert(xs[3] == 4)
        \\    xs.insert(0, 0)
        \\    assert(xs[0] == 0)
        \\    assert(xs[4] == 4)
        \\    assert(len(xs) == 5)
        \\
    );
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var past = 4
        \\    xs.insert(past, 9)
        \\
    , .index_bounds);
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var below = -1
        \\    xs.insert(below, 9)
        \\
    , .index_bounds);
}

test "bounds: a list slice is half-open, and an inverted one is refused" {
    try agreeOk(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var whole = xs[0:3]
        \\    assert(len(whole) == 3)
        \\    var nothing = xs[3:3]
        \\    assert(len(nothing) == 0)
        \\
    );
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var past = 4
        \\    var bad = xs[0:past]
        \\
    , .index_bounds);
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var high = 3
        \\    var low = 1
        \\    var bad = xs[high:low]
        \\
    , .index_bounds);
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var below = -1
        \\    var bad = xs[below:2]
        \\
    , .index_bounds);
}

test "bounds: pop empties a list before it has nothing to answer" {
    try agreeOk(
        \\func main():
        \\    var xs = [1]
        \\    assert(xs.pop() == 1)
        \\    assert(len(xs) == 0)
        \\
    );
    try agreeTrap(
        \\func main():
        \\    var xs = [1]
        \\    let first = xs.pop()
        \\    let nothing = xs.pop()
        \\
    , .empty_collection);
}

test "bounds: every axis of an array is checked on its own" {
    try agreeOk(
        \\func main():
        \\    var grid = array[i64](2, 3)
        \\    var row = 1
        \\    var column = 2
        \\    grid[row, column] = 7
        \\    assert(grid[1, 2] == 7)
        \\
    );
    try agreeTrap(
        \\func main():
        \\    var grid = array[i64](2, 3)
        \\    var row = 2
        \\    let bad = grid[row, 0]
        \\
    , .index_bounds);
    try agreeTrap(
        \\func main():
        \\    var grid = array[i64](2, 3)
        \\    var column = 3
        \\    let bad = grid[0, column]
        \\
    , .index_bounds);
    try agreeTrap(
        \\func main():
        \\    var grid = array[i64](2, 3)
        \\    var below = -1
        \\    let bad = grid[0, below]
        \\
    , .index_bounds);
}

test "bounds: a map answers for a key it holds and traps for one it does not" {
    try agreeOk(
        \\func main():
        \\    var m = map[str, i64]()
        \\    m["a"] = 1
        \\    assert(m["a"] == 1)
        \\    assert(m.has("a"))
        \\    assert(not m.has("b"))
        \\    assert((m.get("b") else 9) == 9)
        \\    m.remove("b")
        \\    assert(len(m) == 1)
        \\
    );
    try agreeTrap(
        \\func main():
        \\    var m = map[str, i64]()
        \\    m["a"] = 1
        \\    var wanted = "b"
        \\    let bad = m[wanted]
        \\
    , .key_missing);
}

test "bounds: str slices use scalar length and byte_at uses byte length" {
    try agreeOk(
        \\func main():
        \\    var s = "abc"
        \\    var end = 3
        \\    assert(s[0:end] == "abc")
        \\    assert(s[end:end] == "")
        \\    assert(s.byte_at(2) == 99)
        \\
    );
    try agreeTrap(
        \\func main():
        \\    var s = "abc"
        \\    var past = 4
        \\    let bad = s[0:past]
        \\
    , .str_bounds);
    try agreeTrap(
        \\func main():
        \\    var s = "abc"
        \\    var past = 3
        \\    let bad = s.byte_at(past)
        \\
    , .str_bounds);
    try agreeOk(
        \\func main():
        \\    var s = "é"
        \\    var middle = 1
        \\    assert(s[0:middle] == "é")
        \\
    );
}

test "trap: array index out of bounds" {
    try agreeTrap(
        \\func main():
        \\    var grid = array[i64](2, 2)
        \\    grid[2, 0] = 1
        \\
    , .index_bounds);
}

test "trap: missing map key" {
    try agreeTrap(
        \\func main():
        \\    var m = map[str, i64]()
        \\    m["present"] = 1
        \\    let bad = m["absent"]
        \\
    , .key_missing);
}

test "trap: popping an empty list" {
    try agreeTrap(
        \\func main():
        \\    var xs = list[i64]()
        \\    let bad = xs.pop()
        \\
    , .empty_collection);
}

test "trap: str index out of bounds" {
    try agreeTrap(
        \\func main():
        \\    var s = "ab"
        \\    let bad = s[0:9]
        \\
    , .str_bounds);
}

test "trap: byte_at past the end of a string" {
    try agreeTrap(
        \\func main():
        \\    var s = "ab"
        \\    let bad = s.byte_at(5)
        \\
    , .str_bounds);
}

test "scalar slicing cannot split a UTF-8 character" {
    try agreeOk(
        \\func main():
        \\    var s = "🙂"
        \\    assert(s[0:1] == "🙂")
        \\
    );
}

test "trap: using an unfilled late object slot" {
    try agreeTrap(
        \\func main():
        \\    var xs: list[i64]
        \\    let bad = len(xs)
        \\
    , .null_object);
}

test "trap: unfilled object slot inside an array of objects" {
    try agreeTrap(
        \\func main():
        \\    var cells = array[list[i64]](2)
        \\    cells[0].append(1)
        \\
    , .null_object);
}

test "arrays: fill retains one shared object for every cell" {
    try agree.prints(
        \\func main():
        \\    var seed = list[i64]()
        \\    seed.append(1)
        \\    var cells = array[list[i64]](3)
        \\    cells.fill(seed)
        \\    seed = list[i64]()
        \\    cells[0].append(2)
        \\    print(str(len(cells[1])))
        \\    print(str(len(cells[2])))
        \\
    , "2\n2\n");
}

test "trap: char conversion of a codepoint beyond Unicode's range" {
    try agreeTrap(
        \\func main():
        \\    var code = 11141111
        \\    let bad = char(code)
        \\
    , .bad_codepoint);
}

// ---------------------------------------------------------------------------
// Whole-feature slices
// ---------------------------------------------------------------------------
//
// These were the interpreter's own suite until the interpreter stopped
// being an engine (docs/ENGINE.md).  Every one of them was always a
// statement about the language rather than about a dispatch loop, so
// they live here and run on both engines like everything else.

/// The four bytes of U+1F642, written where a Luce string literal has
/// to carry them: the lexer's escape set is `\n \t \r \\ \"` and
/// nothing else, so a codepoint above ASCII arrives as itself.
const smiley = "\xF0\x9F\x99\x82";

test "strings: the carriage-return escape decodes to one scalar" {
    // Protocol text ends lines with \r\n; the escape exists so that
    // text can be written without spelling char(13) around every
    // frame.  One scalar, distinct from \n, identical in a char
    // literal and a string.
    try agreeOk(
        \\func main():
        \\    let crlf = "\r\n"
        \\    assert(len(crlf) == 2)
        \\    assert(crlf[0] == '\r')
        \\    assert(crlf[0] == char(13))
        \\    assert(crlf[1] == '\n')
        \\    assert(crlf[0] != crlf[1])
        \\    assert("a\rb" == "a" + str(char(13)) + "b")
        \\
    );
}

test "catch: a diverging handler initializes a binding on both engines" {
    // `let a = risky() catch:` with a handler that always leaves —
    // the success path reads the value, the failure path never
    // reaches the read, and the reason binding still arrives.
    try agreeOk(
        \\func risky(fail: bool) -> i64!:
        \\    if fail:
        \\        error("refused")
        \\    return 7
        \\
        \\func read(fail: bool) -> i64:
        \\    let a = risky(fail) catch:
        \\        return -1
        \\    return a + 1
        \\
        \\func told(fail: bool) -> str:
        \\    var b = risky(fail) catch reason:
        \\        return reason
        \\    b += 1
        \\    return str(b)
        \\
        \\func main():
        \\    assert(read(false) == 8)
        \\    assert(read(true) == -1)
        \\    assert(told(false) == "8")
        \\    assert(told(true) == "refused")
        \\
    );
}

test "structs: a smooth pointer transform computes exactly" {
    try agreeOk(
        \\struct Point:
        \\    x: f64
        \\    y: f64
        \\
        \\func smooth(current: Point, target: Point, amount: f64) -> Point:
        \\    return Point(
        \\        x = current.x + (target.x - current.x) * amount,
        \\        y = current.y + (target.y - current.y) * amount,
        \\    )
        \\
        \\func main():
        \\    let previous = Point(x = 0.0, y = 0.0)
        \\    let pointer = Point(x = 10.0, y = -4.0)
        \\    let eased = smooth(previous, pointer, 0.25)
        \\    assert(eased.x == 2.5)
        \\    assert(eased.y == -1.0)
        \\
    );
}

test "structs: namespaced functions execute through qualified calls" {
    try agreeOk(
        \\struct Math:
        \\    static func twice(value: i64) -> i64:
        \\        return value * 2
        \\
        \\    static func plus(left: i64, right: i64) -> i64:
        \\        return left + right
        \\
        \\func main():
        \\    assert(Math.twice(Math.plus(3, 4)) == 14)
        \\
    );
}

test "loops, recursion, strings, and builtins compute" {
    try agreeOk(
        \\func factorial(value: i64) -> i64:
        \\    if value <= 1:
        \\        return 1
        \\    return value * factorial(value - 1)
        \\
        \\func main():
        \\    var total: i64 = 0
        \\    for index in range(1, 11):
        \\        total = total + index
        \\    assert(total == 55)
        \\    assert(factorial(10) == 3628800)
        \\    assert("sum " + "of ten" == "sum of ten")
        \\    assert(min(clamp(total, 0, 40), abs(-3)) == 3)
        \\
    );
}

test "checked str intrinsics slice and inspect UTF-8 bytes" {
    try agreeOk("func main():\n" ++
        "    let text = \"ab" ++ smiley ++ "cd\\nnext\"\n" ++
        "    assert(text[0:2] == \"ab\")\n" ++
        "    assert(text[2:3] == \"" ++ smiley ++ "\")\n" ++
        "    assert(text.byte_at(2) == 240)\n");
}

test "str intrinsics implement multiline scalar-safe edits" {
    try agreeOk("func inserted(text: str, cursor: i64, added: str) -> str:\n" ++
        "    return text[0:cursor] + added + text[cursor:len(text)]\n" ++
        "\n" ++
        "func erased(text: str, cursor: i64) -> str:\n" ++
        "    let before = cursor - 1\n" ++
        "    return text[0:before] + text[cursor:len(text)]\n" ++
        "\n" ++
        "func main():\n" ++
        "    let original = \"A" ++ smiley ++ "\\nB\"\n" ++
        "    assert(inserted(original, 2, \"x\") == \"A" ++ smiley ++ "x\\nB\")\n" ++
        "    assert(erased(original, 2) == \"A\\nB\")\n");
}

test "checked str intrinsics trap on scalar and byte bounds" {
    const text = "\"a" ++ smiley ++ "b\"";
    const cases = [_]struct { edit: []const u8, code: mir.TrapCode }{
        .{ .edit = "assert(len(" ++ text ++ "[-1:0]) == 0)", .code = .str_bounds },
        .{ .edit = "assert(len(" ++ text ++ "[0:4]) == 0)", .code = .str_bounds },
        .{ .edit = "assert(" ++ text ++ ".byte_at(6) == 0)", .code = .str_bounds },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(
            testing.allocator,
            "func main():\n    {s}\n",
            .{case.edit},
        );
        defer testing.allocator.free(source);
        try agreeTrap(source, case.code);
    }
}

test "checked arithmetic and conversions trap" {
    // Each body is written where its numbers fit: a literal has no
    // type until it lands, so the overflow at 2^63 says `i64` and
    // the conversion out of a value only binary64 holds says `f64`
    // (docs/TYPES.md §1).
    const cases = [_]struct { body: []const u8, code: mir.TrapCode }{
        .{ .body = "var n: i64 = 9223372036854775807\n    assert(n + 1 == 0)", .code = .integer_overflow },
        .{ .body = "var n: i32 = 2147483647\n    assert(n + 1 == 0)", .code = .integer_overflow },
        .{ .body = "assert(1 // (2 - 2) == 0)", .code = .divide_by_zero },
        .{ .body = "var big: f64 = 1.0e300\n    assert(i64(big) == 0)", .code = .conversion_range },
        .{ .body = "var big: f32 = 1.0e30\n    assert(i32(big) == 0)", .code = .conversion_range },
        .{ .body = "assert(1 == 0)", .code = .assertion_failed },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(
            testing.allocator,
            "func main():\n    {s}\n",
            .{case.body},
        );
        defer testing.allocator.free(source);
        try agreeTrap(source, case.code);
    }

    // `trap(...)` carries the program's own words, and both engines
    // hand them back unchanged.
    var explicit = try agree.compare(
        \\func main():
        \\    trap("torn seam")
        \\
    , budget);
    defer explicit.deinit();
    try testing.expectEqual(mir.TrapCode.explicit_trap, explicit.end.trapped);
    try testing.expectEqualStrings("torn seam", explicit.message());
}

test "unbounded recursion hits the call depth limit" {
    try agreeTrap(
        \\func dive(depth: i64) -> i64:
        \\    return dive(depth + 1)
        \\
        \\func main():
        \\    assert(dive(0) == 0)
        \\
    , .call_depth_exceeded);
}

test "lists grow, index, slice, iterate, and free explicitly" {
    try agreeOk(
        \\func main():
        \\    var xs = [3, 1, 2]
        \\    assert(len(xs) == 3)
        \\    xs.append(9)
        \\    assert(xs[3] == 9)
        \\    xs[0] = 30
        \\    assert(xs[0] == 30)
        \\    xs.insert(1, 7)
        \\    assert(xs[1] == 7)
        \\    xs.remove(0)
        \\    assert(xs[0] == 7)
        \\    assert(xs.pop() == 9)
        \\    var total = 0
        \\    for x in xs:
        \\        total = total + x
        \\    assert(total == 10)
        \\    let mid = xs[1:]
        \\    assert(len(mid) == 2)
        \\    assert(mid[0] == 1)
        \\    assert(mid != xs)
        \\    assert(xs == xs)
        \\
    );
}

test "maps upsert, look up, and iterate keys in insertion order" {
    try agreeOk(
        \\func main():
        \\    var ages = map[str, i64]()
        \\    ages["ada"] = 36
        \\    ages["alan"] = 41
        \\    ages["ada"] = 37
        \\    assert(len(ages) == 2)
        \\    assert(ages["ada"] == 37)
        \\    assert(ages.has("alan"))
        \\    var joined = builder()
        \\    for key in ages:
        \\        joined.append(key)
        \\    assert(joined.build() == "adaalan")
        \\    ages.remove("alan")
        \\    assert(not ages.has("alan"))
        \\    ages.remove("ghost")
        \\    assert(len(ages) == 1)
        \\
    );
}

test "arrays are fixed, zeroed, multi-dimensional, and typed" {
    try agreeOk(
        \\func corner(grid: array[i64, _, _]) -> i64:
        \\    return grid[grid.dim(0) - 1, grid.dim(1) - 1]
        \\
        \\func main():
        \\    var grid = array[i64](3, 4)
        \\    assert(grid.dim(0) == 3)
        \\    assert(grid.dim(1) == 4)
        \\    assert(len(grid) == 3)
        \\    assert(grid[2, 3] == 0)
        \\    grid[2, 3] = 7
        \\    assert(corner(grid) == 7)
        \\    var row = array[f64](4)
        \\    row[0] = 2.5
        \\    var total: f64 = 0.0
        \\    for value in row:
        \\        total = total + value
        \\    assert(total == 2.5)
        \\
    );
}

test "conversions: str, parsing, and char over every scalar kind" {
    try agreeOk(
        \\func main():
        \\    assert(str(42) == "42")
        \\    assert(str(-7) == "-7")
        \\    assert(str(true) == "true")
        \\    assert(str(2.5) == "2.5")
        \\    assert((parse_i64("123") else 0) == 123)
        \\    assert((parse_i64("-9") else 0) == 0 - 9)
        \\    assert((parse_f64("2.5") else 0.0) == 2.5)
        \\    assert(parse_i64("twelve") == none)
        \\    assert(str(char(65)) == "A")
        \\    assert(str(char(955)) == "λ")
        \\    assert(u32('λ') == u32(955))
        \\    assert(u32('A') == u32(65))
        \\
    );
}

test "collection misuse traps with stable codes" {
    const cases = [_]struct { source: []const u8, code: mir.TrapCode }{
        .{ .source =
        \\func main():
        \\    let xs = [1]
        \\    let bad = xs[5]
        \\
        , .code = .index_bounds },
        .{ .source =
        \\func main():
        \\    var xs: list[i64] = []
        \\    let bad = xs.pop()
        \\
        , .code = .empty_collection },
        .{ .source =
        \\func main():
        \\    var m = map[str, i64]()
        \\    let bad = m["ghost"]
        \\
        , .code = .key_missing },
        .{ .source =
        \\func main():
        \\    var cells = array[list[i64]](2)
        \\    cells[0].append(1)
        \\
        , .code = .null_object },
        .{ .source =
        \\func main():
        \\    let bad = char(11141111)
        \\
        , .code = .bad_codepoint },
        .{ .source =
        \\func main():
        \\    var grid = array[i64](2, 2)
        \\    grid[2, 0] = 1
        \\
        , .code = .index_bounds },
    };
    for (cases) |case| try agreeTrap(case.source, case.code);
}

test "S33: ARC leaves no live objects after a clean run" {
    try agreeOk(
        \\func main():
        \\    let kept = [1, 2, 3]
        \\    let copied = kept[0:2]
        \\    var released = builder()
        \\    assert(len(copied) == 2)
        \\
    );
}

test "list and array methods: sort, reverse, find, contains, fill, clear" {
    try agreeOk(
        \\func main():
        \\    var xs = [3, 1, 4, 1, 5]
        \\    xs.sort()
        \\    assert(xs[0] == 1)
        \\    assert(xs[4] == 5)
        \\    xs.reverse()
        \\    assert(xs[0] == 5)
        \\    assert((xs.find(4) else -1) == 1)
        \\    assert(xs.find(9) == none)
        \\    assert(xs.contains(3))
        \\    assert(not xs.contains(9))
        \\    xs.clear()
        \\    assert(len(xs) == 0)
        \\    var names = ["cyan", "amber"]
        \\    names.sort()
        \\    assert(names[0] == "amber")
        \\    assert(names[1] == "cyan")
        \\    var row = array[i64](4)
        \\    row.fill(7)
        \\    assert(row[3] == 7)
        \\    assert(row.contains(7))
        \\    row[1] = 2
        \\    row.sort()
        \\    assert(row[0] == 2)
        \\    var ages = map[str, i64]()
        \\    ages["ada"] = 36
        \\    ages["alan"] = 41
        \\    var listed = ages.keys()
        \\    assert(len(listed) == 2)
        \\    assert(listed[0] == "ada" and listed[1] == "alan")
        \\    ages.clear()
        \\    assert(len(ages) == 0)
        \\
    );
}

test "short-circuit operands survive block splits everywhere" {
    // Every multi-operand construct with a splitting (and/or) operand
    // once emitted registers across block boundaries; the verifier
    // rejected the program as an internal compiler error.
    try agreeOk(
        \\struct Flags:
        \\    left: bool
        \\    right: bool
        \\
        \\func pick(first: bool, second: bool) -> bool:
        \\    return first or second
        \\
        \\func main():
        \\    let a = true
        \\    let b = false
        \\    var cells = array[bool](2, 2)
        \\    cells[0, 1] = a == b or a
        \\    let chosen = pick(a and b, a or b)
        \\    let pair = Flags(left = a or b, right = a and b)
        \\    var flags = [a or b, pair.left, cells[0, 1] and chosen]
        \\    flags.append(a or b)
        \\    let compared = (a or b) == (a and b)
        \\    let sliced = flags[0:len(flags)]
        \\    for index in range(0, len(sliced)):
        \\        let unused = sliced[index] or compared
        \\
    );
}

test "file-scope constants fold every value kind" {
    try agreeOk(
        \\const width = 80
        \\const tau = 2.0 * pi
        \\const pi = 3.14159
        \\const debug = not (width > 100)
        \\const greeting = "hello, " + "loom"
        \\const shout = greeting
        \\const half_width = width // 2 - 1
        \\const truncated = i64(tau)
        \\const widened = f64(width)
        \\const roomy = width >= 80 and tau > 6.0
        \\
        \\func main():
        \\    assert(width == 80)
        \\    assert(half_width == 39)
        \\    assert(tau > 6.28 and tau < 6.29)
        \\    assert(debug)
        \\    assert(greeting == "hello, loom")
        \\    assert(shout == "hello, loom")
        \\    assert(truncated == 6)
        \\    assert(widened == 80.0)
        \\    assert(roomy)
        \\    var xs = [width, half_width]
        \\    assert(xs[0] + xs[1] == 119)
        \\
    );
}

test "file-scope constants: an annotated none folds to the typed absence" {
    // D9 of docs/ARGS.md: `none` is a constant when something says
    // what it is absent *of*, and an annotation says.  The gap it
    // closes: `T?` shipped without file-scope absences, for no reason
    // beyond the folder predating it.
    try agreeOk(
        \\const missing: i64? = none
        \\const fallback = 4
        \\
        \\func main():
        \\    assert((missing else fallback) == 4)
        \\    assert(missing == none)
        \\    var slot: i64? = missing
        \\    assert((slot else 0) == 0)
        \\    assert(slot == none)
        \\
    );
}

test "struct constants: the Theme case" {
    try agreeOk(
        \\struct Theme:
        \\    keyword: i64
        \\    comment: i64
        \\    bold: bool
        \\
        \\const theme = Theme(keyword = 114, comment = 238, bold = true)
        \\const accent = theme.keyword + 1
        \\
        \\func main():
        \\    assert(theme.keyword == 114)
        \\    assert(theme.comment == 238)
        \\    assert(theme.bold)
        \\    assert(accent == 115)
        \\    let local_copy = theme
        \\    assert(local_copy.keyword == 114)
        \\
    );
}

// ---------------------------------------------------------------------------
// Where a trap says it happened
// ---------------------------------------------------------------------------
//
// A debug build carries per-instruction origins on both paths: the
// interpreter walks its intact frame stack, a compiled artifact
// records the unwind path as each frame returns trapped
// (docs/MODES.md).  Every trace below is compared frame for frame
// between the two, so "the same trace" is a fact rather than a hope.

test "a trap reports its statement's line and the full call trace" {
    var session = try agree.compare(
        \\func divide(a: i64, b: i64) -> i64:
        \\    return a // b
        \\
        \\func ratio(n: i64) -> i64:
        \\    return divide(100, n)
        \\
        \\func main():
        \\    let x = ratio(0)
        \\
    , budget);
    defer session.deinit();

    try testing.expectEqual(mir.TrapCode.divide_by_zero, session.end.trapped);
    try testing.expectEqualStrings(
        \\divide test.luc:2:5
        \\ratio test.luc:5:5
        \\main test.luc:8:5
        \\
    , session.trace());
}

test "a stripped program still names its trap frames, without lines" {
    var compiled = try agree.program(
        \\func boom() -> i64:
        \\    return 1 // 0
        \\
        \\func main():
        \\    let x = boom()
        \\
    );
    defer compiled.deinit();
    mir.strip(&compiled);

    var session = try agree.compareProgram(&compiled, budget);
    defer session.deinit();
    try testing.expectEqualStrings(
        \\boom :0:0
        \\main :0:0
        \\
    , session.trace());
}

test "a trap inside std code points into the std module" {
    var session = try agree.compare(
        \\import std.strings
        \\
        \\func main():
        \\    var decimals = -1
        \\    let bad = strings.format_float(1.0, decimals)
        \\
    , budget);
    defer session.deinit();

    try testing.expectEqual(mir.TrapCode.explicit_trap, session.end.trapped);
    const reported = session.trace();
    try testing.expect(std.mem.startsWith(
        u8,
        reported,
        "strings.format_float std/strings.luc:",
    ));
    try testing.expect(std.mem.endsWith(u8, reported, "\nmain test.luc:5:5\n"));
}

test "a runaway recursion reports a capped trace and counts the rest" {
    // Sixty-four frames kept, the rest counted — on both engines, from
    // the same depth limit.
    var session = try agree.compare(
        \\func spiral(n: i64) -> i64:
        \\    return spiral(n + 1)
        \\
        \\func main():
        \\    let x = spiral(0)
        \\
    , .{ .call_depth = 100 });
    defer session.deinit();

    try testing.expectEqual(mir.TrapCode.call_depth_exceeded, session.end.trapped);
    const reported = session.trace();
    try testing.expect(std.mem.startsWith(u8, reported, "spiral test.luc:2:5\n"));
    try testing.expect(std.mem.endsWith(u8, reported, "... 36 more\n"));
    try testing.expectEqual(@as(usize, 65), std.mem.count(u8, reported, "\n"));
}

// ---------------------------------------------------------------------------
// Explicit narrow widths compute at their declared width
// ---------------------------------------------------------------------------

test "explicit widths: narrow integers hold their complete ranges" {
    try agreeOk(
        \\func main():
        \\    let low: u8 = 0
        \\    let high: u8 = 255
        \\    let bottom: i16 = -32768
        \\    let top: i16 = 32767
        \\    assert(low == 0)
        \\    assert(high == 255)
        \\    assert(bottom == -32768)
        \\    assert(top == 32767)
        \\    assert(str(high) == "255")
        \\    assert(str(bottom) == "-32768")
        \\
    );
}

test "explicit widths: every integer range and operator survives both engines" {
    try agreeOk(
        \\func main():
        \\    let u8_high: u8 = 255
        \\    let u16_high: u16 = 65535
        \\    let u32_high: u32 = 4294967295
        \\    let u64_high: u64 = 18446744073709551615
        \\    let i8_low: i8 = -128
        \\    let i16_low: i16 = -32768
        \\    let i32_low: i32 = -2147483648
        \\    let i64_low: i64 = -9223372036854775808
        \\    assert(u8_high - 1 == 254)
        \\    assert(u16_high - 1 == 65534)
        \\    assert(u32_high - 1 == 4294967294)
        \\    assert(u64_high - 1 == 18446744073709551614)
        \\    assert(i8_low + 1 == -127)
        \\    assert(i16_low + 1 == -32767)
        \\    assert(i32_low + 1 == -2147483647)
        \\    assert(i64_low + 1 == -9223372036854775807)
        \\    assert(~u8(0) == u8(255))
        \\    assert(~u16(0) == u16(65535))
        \\    assert(~u32(0) == u32(4294967295))
        \\    assert(~u64(0) == u64(18446744073709551615))
        \\    assert(i8(-8) >> 1 == i8(-4))
        \\    assert(i16(-8) >> 1 == i16(-4))
        \\    assert(i32(-8) >> 1 == i32(-4))
        \\    assert(i64(-8) >> 1 == i64(-4))
        \\    assert(u8(9) // u8(2) == u8(4))
        \\    assert(u16(9) % u16(2) == u16(1))
        \\    assert(i32(-9) // i32(2) == i32(-5))
        \\    assert(i64(-9) % i64(2) == i64(1))
        \\
    );
}

test "explicit widths: every integer width is a distinct map key" {
    try agreeOk(
        \\func main():
        \\    var u8s = map[u8, str]()
        \\    var u16s = map[u16, str]()
        \\    var u32s = map[u32, str]()
        \\    var u64s = map[u64, str]()
        \\    var i8s = map[i8, str]()
        \\    var i16s = map[i16, str]()
        \\    var i32s = map[i32, str]()
        \\    var i64s = map[i64, str]()
        \\    u8s[u8(255)] = "u8"
        \\    u16s[u16(65535)] = "u16"
        \\    u32s[u32(4294967295)] = "u32"
        \\    u64s[u64(18446744073709551615)] = "u64"
        \\    i8s[i8(-128)] = "i8"
        \\    i16s[i16(-32768)] = "i16"
        \\    i32s[i32(-2147483648)] = "i32"
        \\    i64s[i64(-9223372036854775808)] = "i64"
        \\    assert(u8s[u8(255)] == "u8" and u8s.has(u8(255)))
        \\    assert(u16s[u16(65535)] == "u16" and u16s.has(u16(65535)))
        \\    assert(u32s[u32(4294967295)] == "u32" and u32s.has(u32(4294967295)))
        \\    assert(u64s[u64(18446744073709551615)] == "u64" and u64s.has(u64(18446744073709551615)))
        \\    assert(i8s[i8(-128)] == "i8" and i8s.has(i8(-128)))
        \\    assert(i16s[i16(-32768)] == "i16" and i16s.has(i16(-32768)))
        \\    assert(i32s[i32(-2147483648)] == "i32" and i32s.has(i32(-2147483648)))
        \\    assert(i64s[i64(-9223372036854775808)] == "i64" and i64s.has(i64(-9223372036854775808)))
        \\
    );
}

test "explicit widths: arithmetic computes in place" {
    try agreeOk(
        \\func main():
        \\    var a: u8 = 200
        \\    var b: u8 = 1
        \\    assert(a + b == 201)
        \\    assert(a * b == 200)
        \\    var s: i16 = 16000
        \\    assert(s + s == 32000)
        \\    var h: f16 = 0.5
        \\    assert(h + h == 1.0)
        \\    assert(h * f16(4.0) == 2.0)
        \\
    );
}

test "explicit widths: scalar math preserves every numeric width" {
    try agreeOk(
        \\func main():
        \\    let a_u8: u8 = 7
        \\    let a_u16: u16 = 7
        \\    let a_u32: u32 = 7
        \\    let a_u64: u64 = 7
        \\    let a_i8: i8 = -7
        \\    let a_i16: i16 = -7
        \\    let a_i32: i32 = -7
        \\    let a_i64: i64 = -7
        \\    assert(abs(a_u8) == u8(7))
        \\    assert(abs(a_u16) == u16(7))
        \\    assert(abs(a_u32) == u32(7))
        \\    assert(abs(a_u64) == u64(7))
        \\    assert(abs(a_i8) == i8(7))
        \\    assert(abs(a_i16) == i16(7))
        \\    assert(abs(a_i32) == i32(7))
        \\    assert(abs(a_i64) == i64(7))
        \\    assert(min(a_u8, u8(9)) == u8(7))
        \\    assert(max(a_u16, u16(9)) == u16(9))
        \\    assert(clamp(a_u32, u32(8), u32(9)) == u32(8))
        \\    assert(min(a_u64, u64(9)) == u64(7))
        \\    assert(max(a_i8, i8(-9)) == i8(-7))
        \\    assert(clamp(a_i16, i16(-6), i16(6)) == i16(-6))
        \\    assert(min(a_i32, i32(-5)) == i32(-7))
        \\    assert(max(a_i64, i64(-9)) == i64(-7))
        \\    let a_f16: f16 = -2.5
        \\    let a_f32: f32 = -2.5
        \\    let a_f64: f64 = -2.5
        \\    assert(abs(a_f16) == f16(2.5))
        \\    assert(abs(a_f32) == f32(2.5))
        \\    assert(abs(a_f64) == f64(2.5))
        \\    assert(min(a_f16, f16(-1.0)) == f16(-2.5))
        \\    assert(max(a_f32, f32(-1.0)) == f32(-1.0))
        \\    assert(clamp(a_f64, f64(-2.0), f64(2.0)) == f64(-2.0))
        \\    let four_f16: f16 = 4.0
        \\    let four_f32: f32 = 4.0
        \\    let four_f64: f64 = 4.0
        \\    assert(sqrt(four_f16) == f16(2.0))
        \\    assert(sqrt(four_f32) == f32(2.0))
        \\    assert(sqrt(four_f64) == f64(2.0))
        \\    assert(floor(a_f16) == f16(-3.0))
        \\    assert(floor(a_f32) == f32(-3.0))
        \\    assert(floor(a_f64) == f64(-3.0))
        \\    assert(ceil(a_f16) == f16(-2.0))
        \\    assert(ceil(a_f32) == f32(-2.0))
        \\    assert(ceil(a_f64) == f64(-2.0))
        \\    assert(trunc(a_f16) == f16(-2.0))
        \\    assert(trunc(a_f32) == f32(-2.0))
        \\    assert(trunc(a_f64) == f64(-2.0))
        \\
    );
}

test "explicit widths: narrow arithmetic traps at its own boundary" {
    try agreeTrap(
        \\func main():
        \\    var high: u8 = 255
        \\    high += 1
        \\
    , .integer_overflow);
    try agreeTrap(
        \\func main():
        \\    var high: i16 = 32767
        \\    high += 1
        \\
    , .integer_overflow);
}

test "explicit widths: integer conversions preserve value" {
    try agreeOk(
        \\func main():
        \\    var b: u8 = 128
        \\    var n: i64 = i64(b)
        \\    assert(n == 128)
        \\    assert(b > 127)
        \\    var s: i16 = -128
        \\    var m: i64 = i64(s)
        \\    assert(m == -128)
        \\    assert(s < 0)
        \\
    );
}

test "explicit widths: byte_at answers u8 and high bytes stay positive" {
    try agreeOk(
        \\func main():
        \\    let text = "é"
        \\    assert(text.byte_at(0) == 195)
        \\    assert(text.byte_at(1) == 169)
        \\    assert(text.byte_at(0) >= 128)
        \\    assert(text.byte_at(0) < 224)
        \\    assert(str(text.byte_at(0)) == "195")
        \\    let plain = "hi"
        \\    assert(plain.find_byte(105, 0) == 1)
        \\    assert(plain.find_byte(plain.byte_at(0), 0) == 0)
        \\
    );
}

// -- conversions, both directions, at every boundary ------------------------

test "explicit widths: checked integer conversions preserve ranges" {
    try agreeOk(
        \\func main():
        \\    assert(u8(0) == 0)
        \\    assert(u8(255) == 255)
        \\    assert(u8(254.6) == 254)
        \\    assert(u8(0.4) == 0)
        \\    assert(i16(-32768) == -32768)
        \\    assert(i16(32767) == 32767)
        \\    assert(i32(u8(200)) == 200)
        \\    assert(i64(i16(-300)) == -300)
        \\
    );
}

test "explicit widths: integer-to-float conversion preserves magnitude" {
    try agreeOk(
        \\func main():
        \\    var high: u8 = 200
        \\    assert(f64(high) == 200.0)
        \\    assert(f32(high) == 200.0)
        \\    assert(f64(high) * 1.0 == 200.0)
        \\    assert(f64(u8(255)) == 255.0)
        \\    var top: u8 = 128
        \\    assert(f64(top) == 128.0)
        \\    var widened: f64 = f64(top)
        \\    assert(widened == 128.0)
        \\
    );
}

test "explicit widths: u8(256) traps rather than wrapping to zero" {
    try agreeTrap(
        \\func main():
        \\    var over: i64 = 256
        \\    var narrowed = u8(over)
        \\    print(str(narrowed))
        \\
    , .conversion_range);
}

test "explicit widths: u8(-1) traps rather than becoming 255" {
    try agreeTrap(
        \\func main():
        \\    var under: i64 = -1
        \\    var narrowed = u8(under)
        \\    print(str(narrowed))
        \\
    , .conversion_range);
}

test "explicit widths: i16 conversions outside the range trap" {
    try agreeTrap(
        \\func main():
        \\    var over: i64 = 32768
        \\    var narrowed = i16(over)
        \\    print(str(narrowed))
        \\
    , .conversion_range);
    try agreeTrap(
        \\func main():
        \\    var under: i64 = -32769
        \\    var narrowed = i16(under)
        \\    print(str(narrowed))
        \\
    , .conversion_range);
}

test "explicit widths: float-to-integer conversion checks after truncation" {
    try agreeOk(
        \\func main():
        \\    assert(u8(255.9) == 255)
        \\
    );
    try agreeTrap(
        \\func main():
        \\    var edge: f64 = 256.0
        \\    var narrowed = u8(edge)
        \\    print(str(narrowed))
        \\
    , .conversion_range);
}

// -- f16: binary16, bit-exact on both engines -------------------------------

test "f16: the boundary values round-trip bit-exactly" {
    // 65504 is the largest finite binary16; 2^-14 is the smallest
    // normal and 2^-24 the smallest subnormal.  The last assert is
    // §3's "shortest representation that round-trips *at its own
    // width*" caught in the act: 65504 prints as "65500", because
    // binary16 has no other value nearer to 65500 and four digits is
    // all it takes to name this one.
    try agreeOk(
        \\func main():
        \\    let biggest: f16 = 65504.0
        \\    let smallest_normal: f16 = 0.00006103515625
        \\    let smallest_subnormal: f16 = 0.000000059604644775390625
        \\    assert(f64(biggest) == 65504.0)
        \\    assert(f64(smallest_normal) == 0.00006103515625)
        \\    assert(f64(smallest_subnormal) == 0.000000059604644775390625)
        \\    assert(str(biggest) == "65500")
        \\
    );
}

test "f16: integers are exact to 2048 and step by two after it" {
    try agreeOk(
        \\func main():
        \\    assert(f64(f16(2048.0)) == 2048.0)
        \\    assert(f64(f16(2049.0)) == 2048.0)
        \\    assert(f64(f16(2050.0)) == 2050.0)
        \\    assert(f64(f16(1025.0)) == 1025.0)
        \\
    );
}

test "f16: overflow reaches infinity rather than trapping" {
    // Floating-point narrowing is IEEE and does not trap (§3), so
    // 1e300 lands on `inf` — and `f16` acquires one far more easily
    // than `f64` does, which is the whole reason the language does
    // not grow a second story about infinity for it.
    try agreeOk(
        \\func main():
        \\    var big: f64 = 1.0e300
        \\    var over = f16(big)
        \\    assert(f64(over) > 65504.0)
        \\    assert(str(over) == "inf")
        \\    var negative = f16(-big)
        \\    assert(str(negative) == "-inf")
        \\
    );
}

test "f16: rounds to nearest, ties to even" {
    // 2049 sits exactly between 2048 and 2050 at binary16; ties to
    // even takes 2048.  2051 sits between 2050 and 2052 and takes
    // 2052 for the same reason.
    try agreeOk(
        \\func main():
        \\    var a: f64 = 2049.0
        \\    var b: f64 = 2051.0
        \\    assert(f64(f16(a)) == 2048.0)
        \\    assert(f64(f16(b)) == 2052.0)
        \\
    );
}

test "f16: f64 to f16 rounds once, not twice through f32" {
    // §7's claim, with a value that can tell the difference — the
    // first draft of this test used 1 + 2^-11 and proved nothing,
    // because a detour through binary32 gives the same answer there.
    //
    // 1 + 2^-11 + 2^-30 is *above* the midpoint between 1.0 and
    // 1 + 2^-10, so rounding it straight to binary16 goes up.  Round
    // it to binary32 first and the 2^-30 falls off — binary32 keeps
    // 23 bits — landing exactly on the midpoint, which then ties to
    // even and goes *down*.  One `fptrunc` answers 1.0009765625; two
    // answer 1.0.
    try agreeOk(
        \\func main():
        \\    var just_above: f64 = 1.0004882821813226
        \\    assert(f64(f16(just_above)) == 1.0009765625)
        \\    var tie: f64 = 1.00048828125
        \\    assert(f64(f16(tie)) == 1.0)
        \\    var exact: f64 = 1.0009765625
        \\    assert(f64(f16(exact)) == 1.0009765625)
        \\
    );
}

test "f16: a non-finite value converted to an integer traps" {
    // The bound `i32` names is not finite at binary16, so the check
    // that catches this is the one that includes its bound rather than
    // excluding it.
    try agreeTrap(
        \\func main():
        \\    var big: f64 = 1.0e300
        \\    var over = f16(big)
        \\    var narrowed = i32(over)
        \\    print(str(narrowed))
        \\
    , .conversion_range);
}

// -- arrays retain each element's declared width ----------------------------

test "explicit widths: an array[u8] stores and reads every value 0..255" {
    try agreeOk(
        \\func main():
        \\    var cells = array[u8](256)
        \\    var at = 0
        \\    while at < 256:
        \\        cells[at] = u8(at)
        \\        at += 1
        \\    assert(cells[0] == 0)
        \\    assert(cells[128] == 128)
        \\    assert(cells[255] == 255)
        \\    var total = 0
        \\    at = 0
        \\    while at < 256:
        \\        total += i64(cells[at])
        \\        at += 1
        \\    assert(total == 32640)
        \\
    );
}

test "explicit widths: arrays of i16 and f16 retain their widths" {
    try agreeOk(
        \\func main():
        \\    var shorts = array[i16](4)
        \\    shorts[0] = -32768
        \\    shorts[3] = 32767
        \\    assert(shorts[0] == -32768)
        \\    assert(shorts[3] == 32767)
        \\    assert(shorts[1] == 0)
        \\    var halves = array[f16](3)
        \\    halves[0] = 0.5
        \\    halves[1] = 65504.0
        \\    assert(f64(halves[0]) == 0.5)
        \\    assert(f64(halves[1]) == 65504.0)
        \\    assert(halves[0] + halves[0] == 1.0)
        \\
    );
}

test "explicit widths: an array store past a u8 element's range traps" {
    try agreeTrap(
        \\func main():
        \\    var cells = array[u8](4)
        \\    var over: i64 = 300
        \\    cells[0] = u8(over)
        \\    print(str(cells[0]))
        \\
    , .conversion_range);
}

test "explicit widths: list[u8] round-trips through the boxed path" {
    try agreeOk(
        \\func main():
        \\    var xs = list[u8]()
        \\    xs.append(0)
        \\    xs.append(255)
        \\    xs.append(128)
        \\    assert(xs[0] == 0)
        \\    assert(xs[1] == 255)
        \\    assert(xs[2] == 128)
        \\    assert(len(xs) == 3)
        \\    xs.sort()
        \\    assert(xs[0] == 0)
        \\    assert(xs[1] == 128)
        \\    assert(xs[2] == 255)
        \\
    );
}

test "explicit widths: struct fields retain their declared widths" {
    try agreeOk(
        \\struct Pixel:
        \\    red: u8
        \\    green: u8
        \\    blue: u8
        \\
        \\func main():
        \\    let p = Pixel(red = 255, green = 128, blue = 0)
        \\    assert(p.red == 255)
        \\    assert(p.green == 128)
        \\    assert(p.blue == 0)
        \\    assert(i64(p.red) + i64(p.green) + i64(p.blue) == 383)
        \\
    );
}

test "explicit widths: parameters and returns retain their widths" {
    try agreeOk(
        \\func lighten(c: u8) -> u8:
        \\    if c > 200:
        \\        return 255
        \\    return u8(c + 40)
        \\
        \\func main():
        \\    assert(lighten(10) == 50)
        \\    assert(lighten(255) == 255)
        \\    assert(lighten(u8(201)) == 255)
        \\
    );
}

// ---------------------------------------------------------------------------
// What a call that raises leaves behind
// ---------------------------------------------------------------------------

test "failure: a call that raises leaves nothing where its value would have gone" {
    // The lowering stores a fallible call's result into the temporary
    // *before* it branches on `errored`, because one register carries
    // both answers.  So what a raising call leaves in that register is
    // load-bearing, and it has to be nothing: inside a loop the
    // register still holds the previous turn's result, whose storage
    // the body has already released.  Storing that into an owning
    // local hands a freed struct run to the release at frame end.
    //
    // Found by `std.zip`: an `inflate` whose bit reader raised on the
    // second turn of the block loop segfaulted the interpreter, while
    // the compiled arm — where a raising call returns a zeroed result
    // — was fine.  This is the two engines saying the same thing.
    try agree.errors(
        \\struct Cursor:
        \\    private position: i64
        \\
        \\    func take(data: list[i64]) -> i64!:
        \\        if self.position >= len(data):
        \\            error("out of bits")
        \\        let value = data[self.position]
        \\        self.position += 1
        \\        return value
        \\
        \\    func drain(data: list[i64], out: list[i64]) -> !:
        \\        while true:
        \\            let value = try self.take(data)
        \\            if value == 0:
        \\                return
        \\            out.append(value)
        \\
        \\func run(data: list[i64]) -> list[i64]!:
        \\    var cursor = Cursor(position = 0)
        \\    var out: list[i64] = []
        \\    try cursor.drain(data, out)
        \\    return out
        \\
        \\func main() -> !:
        \\    var data: list[i64] = [7, 9]
        \\    let back = try run(data)
        \\
    , budget, .user_error, "out of bits");
}
