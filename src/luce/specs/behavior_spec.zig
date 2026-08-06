//! Behavioral correctness suite for the Luce language.
//!
//! Zig's test/behavior proves the language does what it says feature
//! by feature; this is our analog.  Each test is a `func main()` whose
//! `assert(...)`s trap on any wrong answer, so a green run means the
//! stated behavior holds — and stays holding, which is the point:
//! this is the regression net under every future compiler change.
//! Organized by feature area, not by anecdote.  Compile errors live
//! in errors_spec.zig; ownership lives in ownership_spec.zig.
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
/// inside holds, and nothing is left alive — scope ownership frees
/// everything, so a nonzero census is a bug in whichever engine
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

// `string(x)` completes the family of conversion constructors, each
// named for the type it produces, and `str` is gone (docs/NUMERICS.md
// §7).  `builder` is why they are not the same function: `str(b)`
// took a heap object, and a scalar constructor should not — a builder
// hands over its text with `b.build()`.

test "string(x) prints every scalar, and builder.build() hands over its own" {
    try agreeOk(
        \\func main():
        \\    assert(string(42) == "42")
        \\    assert(string(-7) == "-7")
        \\    assert(string(2.5) == "2.5")
        \\    assert(string(3.0) == "3")
        \\    assert(string(true) == "true")
        \\    assert(string(false) == "false")
        \\    assert(string("already") == "already")
        \\    var b = new builder()
        \\    b.append("he")
        \\    b.append("llo")
        \\    assert(b.build() == "hello")
        \\    # `build` takes a snapshot; the builder is still usable.
        \\    b.append("!")
        \\    assert(b.build() == "hello!")
        \\    assert(len(b) == 6)
        \\    free(b)
        \\
    );
}

// `{x:.2f}` — format specs inside f-strings, and nowhere else,
// because that is where formatting happens (docs/NUMERICS.md §8).
// One form: `.Nf` on a double.  It lowers to `strings.format_float`,
// which already existed and already rounds half away from zero, so
// this is one production in the f-string scanner and no runtime.

test "f-strings: a :.Nf spec writes a double to N decimal places" {
    try agree.printsGiven(
        \\import std.strings
        \\
        \\func main():
        \\    let mean = 23.998425
        \\    print(f"mean = {mean:.2f}")
        \\    let rate = 1.0 / 3.0
        \\    print(f"{3} rolls, {rate:.3f}/s")
        \\    # Rounding is the language's, half away from zero.
        \\    print(f"{2.5:.0f} {-2.5:.0f}")
        \\    # Promotion reaches the spec too: a long widens into it.
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
        \\    free(sliced)
        \\    free(parts)
        \\
    , budget, "2 b 3\nel\n");
}

test "str is a name a program may take now" {
    // It left the reserved list with the builtin, so the language got
    // one word smaller in both senses (docs/NUMERICS.md §7).
    try agreeOk(
        \\func str(n: long) -> long:
        \\    return n * 2
        \\
        \\func main():
        \\    assert(str(21) == 42)
        \\
    );
}

test "string(x) folds in a constant, in the same bytes a run would print" {
    try agreeOk(
        \\let count = string(42)
        \\let ratio = string(2.5)
        \\let flag = string(true)
        \\let same = string("x")
        \\let joined = count + " " + ratio + " " + flag + " " + same
        \\
        \\func main():
        \\    assert(joined == "42 2.5 true x")
        \\    assert(string(42) == count)
        \\    assert(string(2.5) == ratio)
        \\
    );
}

// `long(x)` **rounds half away from zero** — the same rounding
// `math.round` was always documented as, because a language with two
// roundings that disagree has a bug in it (docs/NUMERICS.md §7).
// `trunc(x)` is how truncation is spelled now, completing the four:
// `floor`, `ceil`, `trunc`, and round.

test "long(x) rounds half away from zero, and trunc keeps truncation" {
    try agreeOk(
        \\func main():
        \\    assert(long(2.5) == 3)
        \\    assert(long(-2.5) == -3)
        \\    assert(long(0.5) == 1)
        \\    assert(long(-0.5) == -1)
        \\    assert(long(2.4) == 2)
        \\    assert(long(-2.4) == -2)
        \\    assert(long(2.6) == 3)
        \\    assert(long(-2.6) == -3)
        \\    assert(long(3.9) == 4)
        \\    assert(long(-3.9) == -4)
        \\    assert(long(7) == 7)
        \\    # Toward zero has a spelling of its own again.
        \\    assert(trunc(2.9) == 2.0)
        \\    assert(trunc(-2.9) == -2.0)
        \\    assert(long(trunc(-2.9)) == -2)
        \\    # And the four roundings are four different answers.
        \\    assert(floor(-2.5) == -3.0)
        \\    assert(ceil(-2.5) == -2.0)
        \\    assert(trunc(-2.5) == -2.0)
        \\    assert(long(-2.5) == -3)
        \\
    );
}

test "long(x) and math.round agree, at the value floor(x + 0.5) gets wrong" {
    // `0.49999999999999994 + 0.5` rounds up to exactly 1.0 in
    // binary64, so the floor of it is 1 where the answer is 0.  That
    // is how `math.round` used to be written; both now split at
    // `trunc`, which is exact.
    try agreeOk(
        \\import std.math
        \\
        \\func main():
        \\    var nearly: double = 0.49999999999999994
        \\    assert(long(nearly) == 0)
        \\    assert(math.round(nearly) == 0.0)
        \\    assert(floor(nearly + 0.5) == 1.0)
        \\    for step in range(-40, 41):
        \\        let x = double(step) / 4.0
        \\        assert(double(long(x)) == math.round(x))
        \\
    );
}

test "trap: long(x) still refuses NaN, the infinities, and out of range" {
    try agreeTrap(
        \\func main():
        \\    var big = 1.0
        \\    while big < 1.0e30:
        \\        big = big * 10.0
        \\    let bad = long(big)
        \\
    , .conversion_range);
    try agreeTrap(
        \\func main():
        \\    var zero = 0.0
        \\    let bad = long(zero / zero)
        \\
    , .conversion_range);
    try agreeTrap(
        \\func main():
        \\    var zero = 0.0
        \\    var one = 1.0
        \\    let bad = long(one / zero)
        \\
    , .conversion_range);
}

// `/` is **real division** and always answers a double
// (docs/NUMERICS.md §2, §4): the classic `1/2 == 0` is the single
// most common cause of surprise for people who do not already think
// in machine words, and the quotient that answers `0` is `1 // 2`.

test "integers: / is real division and answers a double" {
    try agreeOk(
        \\func main():
        \\    assert(1 / 2 == 0.5)
        \\    assert(7 / 2 == 3.5)
        \\    assert(-7 / 2 == -3.5)
        \\    assert(6 / 3 == 2.0)
        \\    assert(6 / 3 == 2)
        \\    let total = 10
        \\    let count = 4
        \\    assert(total / count == 2.5)
        \\
    );
}

test "integers: / never traps, and 1 / 0 is inf" {
    // The operators that produce a long keep integer semantics,
    // including the trap; the one that produces a double is IEEE like
    // every other double operation (docs/NUMERICS.md §4).
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
        \\    # And `minInt / -1`, which the long quotient could not hold.
        \\    var low: long = -9223372036854775808
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
        \\    var low: long = -9223372036854775808
        \\    var minus_one = -1
        \\    let bad = low // minus_one
        \\
    , .integer_overflow);
    // The same overflow at the other arithmetic width: `minInt // -1`
    // is one value past the top at 32 bits exactly as it is at 64
    // (docs/TYPES.md §4), and the check is per-width or it is wrong.
    try agreeTrap(
        \\func main():
        \\    var low: int = -2147483648
        \\    var minus_one: int = -1
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
    // Promotion would otherwise put a discontinuity here: `-7 % 3`
    // answering 2 and `-7 % 3.0` answering -1.0, with an invisible
    // widening choosing between them.
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
        \\    # Promotion crosses the line without a seam in it.
        \\    assert(-7 % 3.0 == 2.0)
        \\    assert(-7.0 % 3 == 2.0)
        \\    assert(-7 // 3.0 == -3.0)
        \\
    );
}

test "integers: the long range is honored" {
    try agreeOk(
        \\func main():
        \\    let high: long = 9223372036854775807
        \\    assert(high > 0)
        \\    assert(high - 1 == 9223372036854775806)
        \\    let low = 0 - high
        \\    assert(low - 1 < low)
        \\
    );
}

test "integers: the int range is honored, at its own end" {
    // The same program one rung down the ladder.  A literal has no
    // type until it lands (docs/TYPES.md §1), so the only difference
    // between this test and the one above is the word in the
    // annotation — which is the whole claim the two of them make
    // together.
    try agreeOk(
        \\func main():
        \\    let high: int = 2147483647
        \\    assert(high > 0)
        \\    assert(high - 1 == 2147483646)
        \\    let low = 0 - high
        \\    assert(low - 1 < low)
        \\
    );
}

test "integers: long's minimum is written the way it reads" {
    // `-9223372036854775808` is a minus and a literal whose magnitude
    // is one past the largest positive long.  Range-checking the
    // magnitude on its own makes the smallest long the one number
    // nobody can spell, so the sign folds into the literal first.
    try agreeOk(
        \\func main():
        \\    let low: long = -9223372036854775808
        \\    assert(low < 0)
        \\    assert(low + 1 == -9223372036854775807)
        \\    assert(low == 0 - 9223372036854775807 - 1)
        \\    let step: long = -9223372036854775808 // 2
        \\    assert(step == -4611686018427387904)
        \\
    );
}

test "integers: int's minimum is written the way it reads too" {
    // The sign folds into the literal before the range check at every
    // width, not only at the one the check used to be written for.
    try agreeOk(
        \\func main():
        \\    let low: int = -2147483648
        \\    assert(low < 0)
        \\    assert(low + 1 == -2147483647)
        \\    assert(low == 0 - 2147483647 - 1)
        \\    let step: int = -2147483648 // 2
        \\    assert(step == -1073741824)
        \\
    );
}

test "integers: long's minimum folds in a file-scope constant too" {
    try agreeOk(
        \\let low: long = -9223372036854775808
        \\let high: long = 9223372036854775807
        \\
        \\func main():
        \\    assert(low < high)
        \\    assert(low + high == -1)
        \\
    );
}

test "a minus does not move where a literal lands" {
    // `lowerUnary` hands the landing type through a negate.  At one
    // integer width and one float width that line was an equivalent
    // mutant — no program could tell whether the literal landed and
    // was then negated, or took the default and widened afterwards.
    // With a ladder the two answer different numbers, and this is the
    // program that says which one is the language's.
    //
    //   * `-0.1` read at binary64 is not binary32's `-0.1` widened.
    //     Off by 1.5e-9, and silent, because the widening is legal.
    //   * `-3000000000` is a `long` only if the literal never took the
    //     default `int` first — if it had, it would not have compiled.
    try agreeOk(
        \\func main():
        \\    let small: double = -0.1
        \\    let plain: double = 0.1
        \\    assert(small == 0.0 - plain)
        \\    let narrow: float = -0.1
        \\    assert(narrow != small)
        \\    let wide: long = -3000000000
        \\    assert(wide + 3000000000 == 0)
        \\    assert(wide < -2147483648)
        \\
    );
}

// ---------------------------------------------------------------------------
// arithmetic on floats and doubles
// ---------------------------------------------------------------------------

test "floats: arithmetic, IEEE division, and builtins" {
    // Unannotated, so these are `float`s — every value here is exact
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
    // a finite `float`, so the bound the old spec wrote is now a
    // statement a `double` place has to hold — which is exactly what
    // makes it worth writing down separately.
    try agreeOk(
        \\func main():
        \\    let sum: double = 1.5 + 2.5
        \\    assert(sum == 4.0)
        \\    let quarter: double = 1.0 / 4.0
        \\    assert(quarter == 0.25)
        \\    let nine: double = 9.0
        \\    assert(sqrt(nine) == 3.0)
        \\    let infinity: double = 1.0 / 0.0
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
        \\    assert(double(n) / x == 3.5)
        \\    assert(long(x) + n == 9)
        \\    assert(double(long(3.9)) == 4.0)
        \\
    );
}

test "mixing: long widens to double in every arithmetic operator" {
    try agreeOk(
        \\func main():
        \\    let n = 7
        \\    let x = 2.0
        \\    assert(n + x == 9.0)
        \\    assert(x + n == 9.0)
        \\    assert(n - x == 5.0)
        \\    assert(x - n == -5.0)
        \\    assert(n * x == 14.0)
        \\    assert(x * n == 14.0)
        \\    assert(n / x == 3.5)
        \\    assert(x / n == 0.2857142857142857)
        \\    assert(n % x == 1.0)
        \\    assert(x % n == 2.0)
        \\
    );
}

test "mixing: a promoted operator answers a double, printed as one" {
    // `string` of a whole double is its shortest round-trip, so "8" and
    // not "8.0" — the division below is what shows the type moved.
    try agree.printsGiven(
        \\func main():
        \\    let n = 7
        \\    print(string(n + 1.0))
        \\    print(string(1 + 0.5))
        \\    print(string(n / 2.0))
        \\    var f = 2.0
        \\    f += 1
        \\    f *= 2
        \\    print(string(f / 8.0))
        \\
    , budget, "8\n1.5\n3.5\n0.75\n");
}

test "mixing: promotion reaches annotations, arguments, returns, and fields" {
    try agreeOk(
        \\struct Point:
        \\    x: double
        \\    y: double
        \\
        \\func scale(by: double) -> double:
        \\    return by * 2
        \\
        \\func whole() -> double:
        \\    return 3
        \\
        \\func maybe_whole(present: bool) -> double?:
        \\    if present:
        \\        return 4
        \\    return none
        \\
        \\func main():
        \\    let f: double = 1
        \\    assert(f == 1.0)
        \\    assert(scale(3) == 6.0)
        \\    assert(whole() == 3.0)
        \\    let p = Point(x = 1, y = 2.5)
        \\    assert(p.x == 1.0)
        \\    # The two widenings compose, in the one order that works.
        \\    let held = maybe_whole(true)
        \\    if held != none:
        \\        assert(held == 4.0)
        \\    assert(maybe_whole(false) == none)
        \\
    );
}

// The names the language answers to are lowercase (docs/TYPES.md D8):
// `long` and `double` for the two widths it has had all along, and
// `bool`, `string`, `list`, `map`, `array`, `builder` beside them.  A
// TitleCase name is always a struct of the reader's own, which is what
// makes the case of a type name say who defined it.
//
// The TitleCase spellings do not resolve at all: a program that
// writes one is told the lowercase name it is written with now.
test "types: the language's own names are lowercase" {
    try agreeOk(
        \\struct Point:
        \\    x: double
        \\    y: double
        \\
        \\func total(xs: list(long)) -> long:
        \\    var sum: long = 0
        \\    for x in xs:
        \\        sum += x
        \\    return sum
        \\
        \\func main():
        \\    let n: long = 7
        \\    let r: double = 2.5
        \\    let s: string = "hi"
        \\    let b: bool = true
        \\    var xs = new list(long)
        \\    xs.append(n)
        \\    xs.append(3)
        \\    var grid = new array(double, 2, 2)
        \\    grid[0, 0] = 1.5
        \\    var counts = new map(string, long)
        \\    counts["a"] = 1
        \\    var text = new builder()
        \\    text.append(s)
        \\    let p = Point(x = 1, y = r)
        \\    assert(total(xs) == 10)
        \\    assert(long(r) == 3)
        \\    assert(double(n) == 7.0)
        \\    assert(string(grid[0, 0] + p.x) == "2.5")
        \\    assert(counts["a"] == 1)
        \\    assert(text.build() == "hi")
        \\    assert(b)
        \\
    );
}

// A numeric literal has no type of its own: it takes the type of the
// place it lands in, and its *text* is read at that type
// (docs/TYPES.md D3).  With one integer width and one float width the
// two readings agree on every value, so nothing here is a claim about
// rounding yet — what it pins is that the landing happens at all, in
// every place a type is written down, including the file-scope `let`
// that used to refuse an integer spelling outright.
test "literals: a number lands on the type its context names" {
    try agreeOk(
        \\let whole: double = 7
        \\let negative: double = -3
        \\let folded: double = 2 * 3 + 1
        \\let plain = 7
        \\
        \\func takes(x: double) -> double:
        \\    return x
        \\
        \\func answers() -> double:
        \\    return 12
        \\
        \\func main():
        \\    assert(whole == 7.0)
        \\    assert(negative == -3.0)
        \\    assert(folded == 7.0)
        \\    assert(plain == 7)
        \\    let local: double = 5
        \\    assert(local == 5.0)
        \\    let held: double? = 6
        \\    assert(held == 6.0)
        \\    assert(takes(8) == 8.0)
        \\    assert(answers() == 12.0)
        \\
    );
}

test "mixing: promotion reaches container elements and min/max/clamp" {
    try agreeOk(
        \\func main():
        \\    var xs: list(double) = [1, 2, 3]
        \\    xs.append(4)
        \\    xs[0] = 9
        \\    assert(xs[0] == 9.0)
        \\    assert(xs[3] == 4.0)
        \\    assert(len(xs) == 4)
        \\    let mixed = [1, 2.5, 3]
        \\    assert(mixed[0] == 1.0)
        \\    assert(mixed[2] == 3.0)
        \\    let plain = [1, 2, 3]
        \\    assert(plain[0] == 1)
        \\    let x = 7.5
        \\    assert(clamp(x, 0, 5) == 5.0)
        \\    assert(min(x, 8) == 7.5)
        \\    assert(max(1, x) == 7.5)
        \\
    );
}

// Comparison across the line is **exact**: it compares the numbers,
// not a conversion of them.  The boundary is 2^53, where a long stops
// surviving `sitofp` — below it every answer agrees with widening and
// above it they part company, which is the whole reason this is a
// call and not a cast (docs/NUMERICS.md §5).

test "mixing: comparison across the line is exact at 2^53, both sides" {
    try agreeOk(
        \\func main():
        \\    var two53: long = 9007199254740992
        \\    var as_float: double = 9007199254740992.0
        \\    assert(two53 == as_float)
        \\    assert(two53 <= as_float)
        \\    assert(as_float == two53)
        \\    # The number that does not survive widening.
        \\    assert(two53 + 1 != as_float)
        \\    assert(two53 + 1 > as_float)
        \\    assert(as_float < two53 + 1)
        \\    assert(not (two53 + 1 == as_float))
        \\    assert(not (two53 + 1 <= as_float))
        \\    # And its neighbour on the other side.
        \\    assert(two53 - 1 < as_float)
        \\    assert(as_float > two53 - 1)
        \\
    );
}

// The row the ladder adds to that table (docs/TYPES.md §5).  2^24 is
// where a binary32 stops holding consecutive integers, and 16,777,216
// is a number ordinary programs reach — which is why `int` against
// `float` gets the same treatment 2^53 got, rather than an argument
// that it is unlikely.

test "mixing: comparison across the line is exact at 2^24, for int against float" {
    try agreeOk(
        \\func main():
        \\    var two24: int = 16777216
        \\    var as_float: float = 16777216.0
        \\    assert(two24 == as_float)
        \\    assert(two24 <= as_float)
        \\    assert(as_float == two24)
        \\    # The number that does not survive widening.
        \\    assert(two24 + 1 != as_float)
        \\    assert(two24 + 1 > as_float)
        \\    assert(as_float < two24 + 1)
        \\    assert(not (two24 + 1 == as_float))
        \\    assert(not (two24 + 1 <= as_float))
        \\    # And its neighbour on the other side.
        \\    assert(two24 - 1 < as_float)
        \\    assert(as_float > two24 - 1)
        \\
    );
}

// The landing rule reaches past an annotation, and each place below
// is one where a literal read at the wrong width would be *silently*
// wrong — a legal widening of the wrong number, not a diagnostic.

test "a constructor lands its argument, so double(0.1) is binary64's" {
    // `double(0.1)` reading `0.1` at binary32 and widening the result
    // gives 0.10000000149011612 — a different number, and one that
    // reaches its place through a conversion the language allows.
    try agreeOk(
        \\func main():
        \\    let annotated: double = 0.1
        \\    assert(double(0.1) == annotated)
        \\    assert(double(0.1) != double(float(0.1)))
        \\    assert(float(0.1) != annotated)
        \\    # And the integer direction: the constructor's own type is
        \\    # the place, so a value past an `int` is not refused for
        \\    # overflowing one nobody wrote.
        \\    assert(long(3000000000) == 3000000000)
        \\
    );
}

test "the width-polymorphic builtins land their arguments too" {
    // `sqrt` answers its operand's float type (docs/TYPES.md §9), so a
    // `double` place given binary32's square root widened would hold a
    // number nobody asked for — and hold it legally, which is what
    // makes this worth pinning rather than trusting.
    try agreeOk(
        \\func main():
        \\    let two: double = 2.0
        \\    let wide: double = sqrt(2.0)
        \\    assert(wide == sqrt(two))
        \\    let narrow: float = sqrt(2.0)
        \\    assert(wide != narrow)
        \\    # abs, min, max and clamp keep the same rule.
        \\    let held: double = abs(-0.1)
        \\    assert(held == 0.1)
        \\    let picked: double = min(0.1, 1.0)
        \\    assert(picked == 0.1)
        \\    let bounded: double = clamp(0.1, 0.0, 1.0)
        \\    assert(bounded == 0.1)
        \\
    );
}

test "mixing: an int against a double is exact everywhere, ends included" {
    // §5's first row, and the one place the lowering may skip the
    // intrinsic: every `int` is exactly a `double`, so `sitofp` and an
    // ordinary `fcmp` answer what comparing the numbers would.  The
    // spec pins the answers rather than the lowering, because the
    // answers are what may not move.
    try agreeOk(
        \\func main():
        \\    var high: int = 2147483647
        \\    var low: int = -2147483648
        \\    var high_double: double = 2147483647.0
        \\    var low_double: double = -2147483648.0
        \\    assert(high == high_double)
        \\    assert(not (high < high_double))
        \\    assert(not (high > high_double))
        \\    assert(low == low_double)
        \\    assert(high > high_double - 0.5)
        \\    assert(high < high_double + 0.5)
        \\    assert(low < low_double + 0.5)
        \\    assert(low > low_double - 0.5)
        \\
    );
}

test "mixing: ordering, equality, and the fraction that breaks a tie" {
    try agreeOk(
        \\func main():
        \\    assert(1 < 1.5)
        \\    assert(1.5 > 1)
        \\    assert(2 > 1.5)
        \\    assert(1.5 < 2)
        \\    assert(1 == 1.0)
        \\    assert(1.0 == 1)
        \\    assert(1 != 1.5)
        \\    assert(-1 > -1.5)
        \\    assert(-2 < -1.5)
        \\    assert(0 >= -0.0)
        \\    assert(0 <= -0.0)
        \\
    );
}

test "mixing: infinity and NaN compare with a long without widening it" {
    try agreeOk(
        \\func main():
        \\    var one: double = 1.0
        \\    var zero: double = 0.0
        \\    let infinity = one / zero
        \\    let nan = zero / zero
        \\    var big: long = 9223372036854775807
        \\    assert(big < infinity)
        \\    assert(infinity > big)
        \\    assert(0 - big - 1 > 0.0 - infinity)
        \\    # NaN is unordered with everything, so only != holds.
        \\    assert(0 != nan)
        \\    assert(not (0 == nan))
        \\    assert(not (0 < nan))
        \\    assert(not (0 > nan))
        \\    assert(not (0 >= nan))
        \\    assert(not (0 <= nan))
        \\
    );
}

test "mixing: an exact comparison folds the same way in a constant" {
    try agreeOk(
        \\let two53: long = 9007199254740992
        \\let after53: long = 9007199254740993
        \\let as_double: double = 9007199254740992.0
        \\let below = two53 == as_double
        \\let above = after53 == as_double
        \\let ordered = as_double < after53
        \\let widened = 1 + 2.5
        \\
        \\func main():
        \\    assert(below)
        \\    assert(not above)
        \\    assert(ordered)
        \\    assert(widened == 3.5)
        \\
    );
}

// ---------------------------------------------------------------------------
// Compound assignment
// ---------------------------------------------------------------------------

test "compound assignment on names: every operator, long and double" {
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
        \\    value: long
        \\
        \\func main():
        \\    var c = Counter(value = 1)
        \\    c.value += 9
        \\    c.value *= 2
        \\    assert(c.value == 20)
        \\    var xs = [1, 2, 3]
        \\    xs[1] += 10
        \\    assert(xs[1] == 12)
        \\    var grid = new array(long, 2, 2)
        \\    grid[1, 1] += 7
        \\    grid[1, 1] -= 2
        \\    assert(grid[1, 1] == 5)
        \\    var m = new map(string, long)
        \\    m["k"] = 5
        \\    m["k"] *= 4
        \\    assert(m["k"] == 20)
        \\
    );
}

test "compound assignment on a storage width combines at its arithmetic type" {
    // D5: no operator computes at a storage width, so `b += 1` on a
    // `byte` is `b = byte(b + 1)` — promote to `int`, combine, narrow
    // back.  Every place form, because the promotion is stated once
    // in `compoundCombine` and all four of them go through it.
    try agreeOk(
        \\struct Pixel:
        \\    level: byte
        \\
        \\func main():
        \\    var b: byte = 250
        \\    b += 5
        \\    assert(b == 255)
        \\    b -= 255
        \\    assert(b == 0)
        \\    var s: short = 32000
        \\    s += 767
        \\    assert(s == 32767)
        \\    var h: half = 1.0
        \\    h += 0.5
        \\    assert(h == 1.5)
        \\    var p = Pixel(level = 100)
        \\    p.level += 55
        \\    assert(p.level == 155)
        \\    var shades = new array(byte, 2)
        \\    shades[0] += 200
        \\    assert(shades[0] == 200)
        \\    var counts = new map(string, byte)
        \\    counts["k"] = 12
        \\    counts["k"] *= 20
        \\    assert(counts["k"] == 240)
        \\
    );
}

test "trap: a storage-width compound assignment narrows back with the range check" {
    // The half of D5 that makes the promotion honest.  `b += 1` at 255
    // is not 0: the narrowing back into the place is the same checked
    // conversion `byte(b + 1)` pays for, so it stops the program
    // rather than wrapping.
    try agreeTrap(
        \\func main():
        \\    var b: byte = 255
        \\    b += 1
        \\    assert(b == 0)
        \\
    , .conversion_range);
}

test "a compound index target evaluates its index expression once" {
    // If `xs[next()]` were evaluated twice the counter would land on
    // 2 and the wrong slot would change; once, it lands on 1.
    try agreeOk(
        \\func main():
        \\    var calls: list(long) = [0]
        \\    var xs = [100, 200, 300]
        \\    xs[bump(calls)] += 5
        \\    assert(calls[0] == 1)
        \\    assert(xs[1] == 205)
        \\    assert(xs[0] == 100)
        \\    assert(xs[2] == 300)
        \\
        \\func bump(counter: list(long)) -> long:
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
        \\func boom(x: long) -> bool:
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
        \\func classify(n: long) -> long:
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
        \\    var total: long = 0
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
        \\func factorial(n: long) -> long:
        \\    if n <= 1:
        \\        return 1
        \\    return n * factorial(n - 1)
        \\
        \\func fib(n: long) -> long:
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
        \\func is_even(n: long) -> bool:
        \\    if n == 0:
        \\        return true
        \\    return is_odd(n - 1)
        \\
        \\func is_odd(n: long) -> bool:
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
    // The 🙂 is four bytes (F0 9F 99 82); slices and byte_at see the
    // real UTF-8, and a slice that keeps it whole is exact.
    try agreeOk(
        \\func main():
        \\    let s = "a🙂b"
        \\    assert(len(s) == 6)
        \\    assert(s[0:1] == "a")
        \\    assert(s[1:5] == "🙂")
        \\    assert(s.byte_at(0) == 97)
        \\    assert(s.byte_at(1) == 240)
        \\
    );
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------

test "conversions: string, parse, chr, ord" {
    try agreeOk(
        \\func main():
        \\    assert(string(42) == "42")
        \\    assert(string(0 - 7) == "-7")
        \\    assert(string(true) == "true")
        \\    assert(string(false) == "false")
        \\    assert((parse_int("100") else 0) == 100)
        \\    assert((parse_float("1.5") else 0.0) == 1.5)
        \\    assert(chr(65) == "A")
        \\    assert(ord("A") == 65)
        \\    assert(chr(955) == "λ")
        \\    assert(ord("λ") == 955)
        \\
    );
}

test "ord of a literal is a compile-time constant" {
    // Folding `ord` is what lets the language do without character
    // literal syntax at all: `byte_at(s, i) == ord("(")` should cost
    // exactly what `== 40` costs, or nobody will write it.
    var compiled = try agree.program(
        \\func main():
        \\    let text = "(x)"
        \\    assert(text.byte_at(0) == ord("("))
        \\
    );
    defer compiled.deinit();
    for (compiled.functions) |function| {
        for (function.instructions) |instruction| {
            if (instruction == .intrinsic and instruction.intrinsic.kind == .ord_text) {
                std.debug.print("ord survived to run time\n", .{});
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "ord folds in a file-scope constant, and an empty one still traps at run time" {
    try agreeOk(
        \\let open_paren = ord("(")
        \\let lambda = ord("λ")
        \\
        \\func main():
        \\    assert(open_paren == 40)
        \\    assert(lambda == 955)
        \\    assert("(a)".byte_at(0) == open_paren)
        \\
    );
    // A literal with no codepoint is left to the run time, so the
    // fold cannot quietly change what the program does.
    try agreeTrap(
        \\func main():
        \\    var empty = ""
        \\    assert(ord(empty) == 0)
        \\
    , .bad_codepoint);
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
        \\func main():
        \\    assert(f"" == "")
        \\    assert(f"plain" == "plain")
        \\    assert(f"tab\tend" == "tab\tend")
        \\    assert(f"braces: {{ }}" == "braces: { }")
        \\    let name = "x"
        \\    assert(f"{name + "!"}" == "x!")
        \\    let n = 5
        \\    assert(f"{n * n} squared" == "25 squared")
        \\
    );
}

test "f-strings compose with methods and calls in holes" {
    try agreeOk(
        \\import std.strings
        \\
        \\func twice(n: long) -> long:
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
        \\    x: long
        \\    y: long
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
        \\    x: long
        \\    y: long
        \\
        \\    func add(a: Vec, b: Vec) -> Vec:
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
// `-> (A, B)`, `return a, b`, `let low, high = f()`.  **There is no
// tuple**: the values exist only in flight, produced by a `return` and
// consumed by a bind, with no moment in between at which a program can
// hold them (docs/RETURNS.md).
//
// Underneath they are one compiler-synthesized struct, which is why
// the oracle needed no edit for any of this either.

test "returns: a shape is declared, returned, and bound" {
    try agreeOk(
        \\func minmax(xs: list(long)) -> (long, long):
        \\    var low = xs[0]
        \\    var high = xs[0]
        \\    for value in xs:
        \\        low = min(low, value)
        \\        high = max(high, value)
        \\    return low, high
        \\
        \\func main():
        \\    var xs: list(long) = [3, 1, 4, 1, 5]
        \\    let low, high = minmax(xs)
        \\    assert(low == 1 and high == 5)
        \\    # `var` governs the whole bind, and both names reassign.
        \\    var a, b = minmax(xs)
        \\    a = a + 1
        \\    b = b + 1
        \\    assert(a == 2 and b == 6)
        \\    free(xs)
        \\
    );
}

test "returns: three values, mixed types, and a shape of shapes' worth of nesting" {
    try agreeOk(
        \\func spread(n: long) -> (long, double, string):
        \\    return n, double(n) / 2.0, string(n)
        \\
        \\func main():
        \\    let count, half, written = spread(7)
        \\    assert(count == 7)
        \\    assert(half == 3.5)
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
        \\func two() -> (list(long), list(long)):
        \\    var head: list(long) = [1]
        \\    var tail: list(long) = [2]
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
        \\func halves(n: long) -> (list(long), list(long)):
        \\    var head = [n]
        \\    var tail = [n + 1]
        \\    return head, tail
        \\
        \\func main():
        \\    let head, tail = halves(7)
        \\    assert(head[0] == 7 and tail[0] == 8)
        \\    head.append(9)
        \\    assert(len(head) == 2 and len(tail) == 1)
        \\    free(head)
        \\    free(tail)
        \\
    );
}

test "returns: T! composes, and try is the only composition there is" {
    try agreeOk(
        \\func pair(n: long) -> (long, long)!:
        \\    if n < 0:
        \\        error("negative")
        \\    return n, n * 2
        \\
        \\func doubled(n: long) -> (long, long)!:
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

test "returns: T? is an ordinary element of a shape" {
    // Absence *is* a value, so a `T?` among the elements needs no rule
    // at all — while `-> (long, long)?` is refused, because there the
    // `?` would be marking the shape (docs/RETURNS.md §2).
    try agreeOk(
        \\func lookup(m: map(string, long), key: string) -> (long?, bool):
        \\    if m.has(key):
        \\        return m[key], true
        \\    return none, false
        \\
        \\func main():
        \\    var ages = new map(string, long)
        \\    ages["ada"] = 36
        \\    let found, present = lookup(ages, "ada")
        \\    assert(present and (found else 0) == 36)
        \\    let missing, there = lookup(ages, "bob")
        \\    assert(not there and missing == none)
        \\    free(ages)
        \\
    );
}

test "returns: a shape crosses a loop as two vars, and the body gets shorter" {
    // The case docs/RETURNS.md's first rule tripped on: loop-carried is
    // not disqualifying, and two `var`s carry a pair as well as one
    // struct did.
    try agreeOk(
        \\func step(value: long, at: long) -> (long, long):
        \\    return value + at, at + 1
        \\
        \\func main():
        \\    var value, at = step(0, 0)
        \\    while at < 5:
        \\        let next_value, next_at = step(value, at)
        \\        value = next_value
        \\        at = next_at
        \\    assert(at == 5)
        \\    assert(value == 10)
        \\
    );
}

// ---------------------------------------------------------------------------
// Methods: `self`
// ---------------------------------------------------------------------------
//
// `p.length()` **is** `Point.length(p)` — the same MIR call, resolved
// in stage 4 (docs/METHODS.md).  Nothing below is a second semantics,
// which is why the oracle needed no edit for any of it and is
// therefore the arm that proves the sugar resolved right.

test "methods: a receiver reads its struct, and the static form is the same call" {
    try agreeOk(
        \\struct Point:
        \\    x: double
        \\    y: double
        \\
        \\    func length(self) -> double:
        \\        return sqrt(self.x * self.x + self.y * self.y)
        \\
        \\    func plus(self, other: Point) -> Point:
        \\        return Point(x = self.x + other.x, y = self.y + other.y)
        \\
        \\    func origin() -> Point:
        \\        return Point(x = 0.0, y = 0.0)
        \\
        \\func main():
        \\    let p = Point(x = 3.0, y = 4.0)
        \\    assert(p.length() == 5.0)
        \\    # The long way round means exactly the same thing, which is
        \\    # what lets a struct convert one function at a time.
        \\    assert(Point.length(p) == 5.0)
        \\    let q = p.plus(Point(x = 1.0, y = 1.0))
        \\    assert(q.x == 4.0 and q.y == 5.0)
        \\    # A namespace function beside the methods, untouched.
        \\    assert(Point.origin().length() == 0.0)
        \\    # And a method on a call result, which needs no place.
        \\    assert(Point.origin().plus(p).length() == 5.0)
        \\
    );
}

test "methods: a receiver is a value, so the method sees a copy" {
    try agreeOk(
        \\struct Counter:
        \\    count: long
        \\
        \\    func bumped(self) -> Counter:
        \\        var next = self
        \\        next.count = next.count + 1
        \\        return next
        \\
        \\func main():
        \\    let one = Counter(count = 1)
        \\    let two = one.bumped()
        \\    assert(two.count == 2)
        \\    # `self` was a copy: nothing about `one` moved.
        \\    assert(one.count == 1)
        \\
    );
}

test "methods: a receiver may be a field, an element, or a chain of both" {
    try agreeOk(
        \\struct Point:
        \\    x: long
        \\
        \\    func doubled(self) -> long:
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
        \\    free(cells)
        \\
    );
}

test "methods: a method may take and answer objects, and ownership is the plain-call rule" {
    try agreeOk(
        \\struct Tally:
        \\    total: long
        \\
        \\    func over(self, values: list(long)) -> long:
        \\        var sum = self.total
        \\        for value in values:
        \\            sum = sum + value
        \\        return sum
        \\
        \\    func spread(self) -> list(long):
        \\        var made = [self.total, self.total]
        \\        return made
        \\
        \\func main():
        \\    let tally = Tally(total = 10)
        \\    var numbers: list(long) = [1, 2, 3]
        \\    assert(tally.over(numbers) == 16)
        \\    var pair = tally.spread()
        \\    assert(len(pair) == 2 and pair[0] == 10)
        \\    free(pair)
        \\    free(numbers)
        \\
    );
}

test "methods: a method can fail, and try and catch reach it through the receiver" {
    try agreeOk(
        \\struct Reader:
        \\    limit: long
        \\
        \\    func check(self, n: long) -> long!:
        \\        if n > self.limit:
        \\            error("over the limit")
        \\        return n
        \\
        \\func under() -> long!:
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
// `var self`: the receiver is result zero
// ---------------------------------------------------------------------------
//
// `p.scale(2.0)` means `p = Point.scale(p, 2.0)` — copy in, copy out,
// with no reference anywhere.  With a declared result beside it,
// `let roll = rng.next()` means `rng, roll = Rng.next(rng)`, and under
// the lowering that is not a second channel at all: the method's
// results are `[receiver] ++ declared` and they travel in one
// synthesized layout (docs/METHODS.md, docs/RETURNS.md §5).

test "var self: the receiver is written back, and nothing about it is a reference" {
    try agreeOk(
        \\struct Point:
        \\    x: double
        \\    y: double
        \\
        \\    func scale(var self, factor: double):
        \\        self.x = self.x * factor
        \\        self.y = self.y * factor
        \\
        \\    func reset(var self):
        \\        # `self` is the one parameter a method may reassign.
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

test "var self: the motivating case, end to end" {
    // The RNG of docs/RETURNS.md §5.  One call where the workaround
    // had a one-element `list(long)` allocated to give an `long`
    // reference semantics.
    try agreeOk(
        \\struct Rng:
        \\    state: long
        \\
        \\    func next(var self) -> long:
        \\        self.state = self.state * 48271 % 2147483647
        \\        return self.state
        \\
        \\    func in_range(var self, low: long, high: long) -> long:
        \\        if high <= low:
        \\            trap("in_range needs low < high")
        \\        return low + self.next() % (high - low)
        \\
        \\func main():
        \\    var rng = Rng(state = 42)
        \\    let roll = rng.in_range(1, 7)
        \\    assert(roll >= 1 and roll < 7)
        \\    # The write-back is invisible at the call site, and it
        \\    # happened: 42 * 48271 is where the state went.
        \\    assert(rng.state == 2027382)
        \\    let second = rng.next()
        \\    assert(second == rng.state)
        \\    assert(second != 2027382)
        \\    # At statement position the declared value is discarded
        \\    # and result zero is still stored.
        \\    let third = rng.state
        \\    rng.next()
        \\    assert(rng.state != third)
        \\
    );
}

test "var self: a receiver may be a field or an element of a var root" {
    try agreeOk(
        \\struct Counter:
        \\    n: long
        \\
        \\    func bump(var self):
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

test "var self: a method that raises leaves its receiver as it was" {
    // All or nothing, and for free: the write-back stands on the
    // returning edge only, which is what `catch`'s branch already
    // gives (docs/FAILURE.md, docs/METHODS.md).
    try agreeOk(
        \\struct Meter:
        \\    reading: long
        \\
        \\    func take(var self, n: long) -> long!:
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
        \\    # Nothing about the receiver moved on the errored edge.
        \\    assert(meter.reading == 15)
        \\
    );
}

test "var self: the read-only static form of a plain method is still the same call" {
    try agreeOk(
        \\struct Point:
        \\    x: long
        \\
        \\    func doubled(self) -> long:
        \\        return self.x * 2
        \\
        \\    func grow(var self):
        \\        self.x = self.x + 1
        \\
        \\func main():
        \\    var p = Point(x = 3)
        \\    assert(p.doubled() == 6)
        \\    assert(Point.doubled(p) == 6)
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
        \\    n: long
        \\
        \\struct Outer:
        \\    label: string
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
        \\    value: long
        \\
        \\func main():
        \\    var cells = [Cell(value = 10), Cell(value = 20)]
        \\    cells[1].value = 99
        \\    assert(cells[1].value == 99)
        \\    assert(cells[0].value == 10)
        \\    cells[0].value += 5
        \\    assert(cells[0].value == 15)
        \\    var grid = new array(Cell, 2, 2)
        \\    grid[1, 1].value = 7
        \\    assert(grid[1, 1].value == 7)
        \\    assert(grid[0, 0].value == 0)
        \\
    );
}

test "a chained index place evaluates its subscript once" {
    try agreeOk(
        \\struct Cell:
        \\    value: long
        \\
        \\func bump(counter: list(long)) -> long:
        \\    counter[0] = counter[0] + 1
        \\    return 1
        \\
        \\func main():
        \\    var calls: list(long) = [0]
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

test "maps: upsert, lookup, membership, keys in insertion order" {
    try agreeOk(
        \\func main():
        \\    var m = new map(string, long)
        \\    m["a"] = 1
        \\    m["b"] = 2
        \\    m["a"] = 3
        \\    assert(len(m) == 2)
        \\    assert(m["a"] == 3)
        \\    assert(m.has("b"))
        \\    assert(not m.has("z"))
        \\    var order = new builder()
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
        \\    var m = new map(string, long)
        \\    m["a"] = 1
        \\    m["b"] = 2
        \\    m["c"] = 3
        \\    var keys = new builder()
        \\    var total: long = 0
        \\    for k, v in m:
        \\        keys.append(k)
        \\        total += v
        \\    assert(keys.build() == "abc")
        \\    assert(total == 6)
        \\    assert(m.get("b", 0) == 2)
        \\    assert(m.get("missing", 99) == 99)
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
        \\    var sum_index: long = 0
        \\    var sum_value = 0
        \\    for i, x in xs:
        \\        sum_index += i
        \\        sum_value += x
        \\    assert(sum_index == 0 + 1 + 2)
        \\    assert(sum_value == 60)
        \\    var row = new array(long, 4)
        \\    row.fill(5)
        \\    var seen: long = 0
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
        \\    var m = new map(long, long)
        \\    m[7] = 70
        \\    m[8] = 80
        \\    var key_sum: long = 0
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
        \\    var grid = new array(long, 3, 4)
        \\    assert(grid.dim(0) == 3 and grid.dim(1) == 4)
        \\    assert(grid[2, 3] == 0)
        \\    grid[2, 3] = 7
        \\    assert(grid[2, 3] == 7)
        \\    var row = new array(long, 5)
        \\    row.fill(9)
        \\    assert(row[0] == 9 and row[4] == 9)
        \\    assert(len(row) == 5)
        \\
    );
}

test "builders accumulate text" {
    try agreeOk(
        \\func main():
        \\    var b = new builder()
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

test "file-scope constants fold and inline" {
    try agreeOk(
        \\let width = 80
        \\let half = width // 2
        \\let name = "loom"
        \\let greeting = "hi " + name
        \\
        \\func main():
        \\    assert(width == 80)
        \\    assert(half == 40)
        \\    assert(greeting == "hi loom")
        \\
    );
}

// ---------------------------------------------------------------------------
// Numeric builtins: abs / min / max / clamp
// ---------------------------------------------------------------------------

test "abs, min, max, clamp on long" {
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

test "abs, min, max, clamp on double" {
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

test "float builtins: sqrt, floor, ceil on exact and fractional inputs" {
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

test "all six comparisons on long" {
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

test "all six comparisons on double" {
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

test "all six comparisons on string use lexicographic byte order" {
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
        \\    a: long
        \\    b: long
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
        \\    var out = new builder()
        \\    for x in xs:
        \\        out.append(string(x))
        \\    assert(out.build() == "456")
        \\
    );
}

test "for-each over a rank-1 array visits every slot" {
    try agreeOk(
        \\func main():
        \\    var row = new array(long, 4)
        \\    row[0] = 1
        \\    row[1] = 2
        \\    row[2] = 3
        \\    row[3] = 4
        \\    var total: long = 0
        \\    for v in row:
        \\        total = total + v
        \\    assert(total == 10)
        \\
    );
}

test "for-each over map keys walks insertion order" {
    try agreeOk(
        \\func main():
        \\    var m = new map(string, long)
        \\    m["x"] = 1
        \\    m["y"] = 2
        \\    m["z"] = 3
        \\    var joined = new builder()
        \\    for k in m.keys():
        \\        joined.append(k)
        \\    assert(joined.build() == "xyz")
        \\
    );
}

test "continue in a for-loop skips the rest of the body" {
    try agreeOk(
        \\func main():
        \\    var total: long = 0
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

test "the explicit frame stack survives a deep iterative-recursive sum" {
    try agreeOk(
        \\func sum_to(n: long) -> long:
        \\    if n == 0:
        \\        return 0
        \\    return n + sum_to(n - 1)
        \\
        \\func main():
        \\    assert(sum_to(4000) == 8002000)
        \\
    );
}

// ---------------------------------------------------------------------------
// Strings: the full method surface
// ---------------------------------------------------------------------------

test "strings: find, contains, starts_with, ends_with" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let s = "hello world"
        \\    assert(s.find("world") == 6)
        \\    assert(s.find("xyz") == 0 - 1)
        \\    assert(s.find("hello") == 0)
        \\    assert(s.contains("lo w"))
        \\    assert(not s.contains("zzz"))
        \\    assert(s.starts_with("hello"))
        \\    assert(not s.starts_with("world"))
        \\    assert(s.ends_with("world"))
        \\    assert(not s.ends_with("hello"))
        \\
    );
}

test "strings: trim, lower, upper, repeat" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    assert("  hi  ".trim() == "hi")
        \\    assert("\t\nhi\n".trim() == "hi")
        \\    assert("".trim() == "")
        \\    assert("MiXeD".lower() == "mixed")
        \\    assert("MiXeD".upper() == "MIXED")
        \\    assert("ab".repeat(3) == "ababab")
        \\    assert("ab".repeat(0) == "")
        \\    assert("x".repeat(1) == "x")
        \\
    );
}

test "strings: replace substitutes every occurrence" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    assert("a.b.c".replace(".", "-") == "a-b-c")
        \\    assert("aaa".replace("a", "bb") == "bbbbbb")
        \\    assert("hello".replace("z", "y") == "hello")
        \\    assert("hello".replace("l", "") == "heo")
        \\
    );
}

test "strings: split on a separator and split on whitespace" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let a = "1,2,3".split(",")
        \\    assert(len(a) == 3)
        \\    assert(a[0] == "1" and a[1] == "2" and a[2] == "3")
        \\    let b = "  the   quick brown  ".split("")
        \\    assert(len(b) == 3)
        \\    assert(b[0] == "the" and b[1] == "quick" and b[2] == "brown")
        \\    let c = "solo".split(",")
        \\    assert(len(c) == 1 and c[0] == "solo")
        \\
    );
}

test "strings: join round-trips split" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let parts = "a-b-c".split("-")
        \\    assert(parts.join("-") == "a-b-c")
        \\    assert(parts.join("") == "abc")
        \\    let two = ["x", "y"]
        \\    assert(two.join(", ") == "x, y")
        \\    let one = ["only"]
        \\    assert(one.join(",") == "only")
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
    // λ is two bytes (CE BB); byte_at exposes each byte and len counts
    // bytes, not codepoints.
    try agreeOk(
        \\func main():
        \\    let s = "λ"
        \\    assert(len(s) == 2)
        \\    assert(s.byte_at(0) == 206)
        \\    assert(s.byte_at(1) == 187)
        \\    let mix = "aλb"
        \\    assert(len(mix) == 4)
        \\    assert(mix.byte_at(0) == 97)
        \\    assert(mix[0:1] == "a")
        \\    assert(mix[1:3] == "λ")
        \\    assert(mix[3:4] == "b")
        \\
    );
}

// ---------------------------------------------------------------------------
// Conversions in depth
// ---------------------------------------------------------------------------

test "string renders every scalar, and a builder hands over its own" {
    try agreeOk(
        \\func main():
        \\    assert(string(0) == "0")
        \\    assert(string(1000000) == "1000000")
        \\    assert(string(1.5) == "1.5")
        \\    assert(string(3.0) == "3")
        \\    assert(string(true) == "true")
        \\    assert(string("already") == "already")
        \\    var b = new builder()
        \\    b.append("bld")
        \\    assert(b.build() == "bld")
        \\
    );
}

test "parse_int and parse_float accept signs and round-trip string" {
    try agreeOk(
        \\func main():
        \\    assert((parse_int("0") else 1) == 0)
        \\    assert((parse_int("-42") else 0) == 0 - 42)
        \\    assert((parse_int("+7") else 0) == 7)
        \\    assert((parse_float("3.25") else 0.0) == 3.25)
        \\    assert((parse_float("-0.5") else 0.0) == 0.0 - 0.5)
        \\    assert((parse_int(string(98765)) else 0) == 98765)
        \\
    );
}

test "parse_int and parse_float answer none rather than trapping" {
    try agreeOk(
        \\func main():
        \\    assert(parse_int("not a number") == none)
        \\    assert(parse_int("4 2") == none)
        \\    assert(parse_int("") == none)
        \\    assert(parse_float("abc") == none)
        \\    assert(parse_float("inf") == none)
        \\    assert(parse_float("nan") == none)
        \\    assert(parse_int("7") != none)
        \\    assert((parse_int("nope") else 0 - 1) == 0 - 1)
        \\    assert((parse_float("nope") else 2.5) == 2.5)
        \\
    );
}

test "chr and ord round-trip across ASCII and multibyte codepoints" {
    try agreeOk(
        \\func main():
        \\    assert(chr(97) == "a")
        \\    assert(ord("a") == 97)
        \\    assert(ord(chr(0)) == 0)
        \\    assert(chr(955) == "λ")
        \\    assert(ord("λ") == 955)
        \\    assert(chr(128578) == "🙂")
        \\    assert(ord("🙂") == 128578)
        \\    assert(ord(chr(128578)) == 128578)
        \\
    );
}

// ---------------------------------------------------------------------------
// Lists: methods, slicing independence, nesting, structs
// ---------------------------------------------------------------------------

test "lists: sort orders long, double, and string in place" {
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
        \\    var xs: list(double) = []
        \\    var i = 0
        \\    while i < 40:
        \\        xs.append(1.0)
        \\        xs.append(-0.0)
        \\        xs.append(0.0)
        \\        i += 1
        \\    xs.sort()
        \\    i = 0
        \\    while i < 40:
        \\        assert(string(xs[i * 2]) == "-0")
        \\        assert(string(xs[i * 2 + 1]) == "0")
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
        \\    assert(xs.find(3) == 1)
        \\    assert(xs.find(99) == 0 - 1)
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

test "lists: nested lists are references shared until copied" {
    try agreeOk(
        \\func main():
        \\    var outer = new list(list(long))
        \\    var inner: list(long) = [1, 2]
        \\    outer.append(give inner)
        \\    outer[0].append(3)
        \\    assert(len(outer[0]) == 3)
        \\    var dup = new list(list(long))
        \\    dup.append(copy outer[0])
        \\    dup[0].append(4)
        \\    assert(len(dup[0]) == 4)
        \\    assert(len(outer[0]) == 3)
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
        \\    v: long
        \\
        \\func main():
        \\    var cells = new list(Cell)
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

test "maps: long keys, lookup, has, and len" {
    try agreeOk(
        \\func main():
        \\    var m = new map(long, string)
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
        \\    var m = new map(string, long)
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
        \\    var m = new map(string, long)
        \\    var i = 0
        \\    while i < 300:
        \\        m["k" + string(i)] = i
        \\        i += 1
        \\    assert(len(m) == 300)
        \\    var seen = 0
        \\    for key, held in m:
        \\        assert(key == "k" + string(held))
        \\        assert(held == seen)
        \\        seen += 1
        \\    assert(seen == 300)
        \\    i = 0
        \\    while i < 300:
        \\        assert(m["k" + string(i)] == i)
        \\        assert(m.has("k" + string(i)))
        \\        i += 1
        \\    i = 0
        \\    while i < 300:
        \\        if i % 2 == 0:
        \\            m.remove("k" + string(i))
        \\        i += 1
        \\    assert(len(m) == 150)
        \\    var next = 1
        \\    for key in m:
        \\        assert(key == "k" + string(next))
        \\        next += 2
        \\    assert(m.get("k5", 0 - 1) == 5)
        \\    assert(m.get("k4", 0 - 1) == 0 - 1)
        \\
    );
}

test "maps: long keys survive growth, negatives, and the extremes" {
    try agreeOk(
        \\func main():
        \\    var m = new map(long, long)
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
        \\    var a1 = new array(long, 5)
        \\    assert(a1.dim(0) == 5 and a1[4] == 0)
        \\    var a2 = new array(long, 2, 3)
        \\    assert(a2.dim(0) == 2 and a2.dim(1) == 3)
        \\    assert(a2[1, 2] == 0)
        \\    var a3 = new array(long, 2, 2, 2)
        \\    assert(a3.dim(2) == 2 and a3[1, 1, 1] == 0)
        \\    a3[1, 1, 1] = 7
        \\    assert(a3[1, 1, 1] == 7 and a3[0, 0, 0] == 0)
        \\    var a4 = new array(long, 2, 2, 2, 2)
        \\    assert(a4.dim(3) == 2 and a4[1, 1, 1, 1] == 0)
        \\    a4[1, 1, 1, 1] = 9
        \\    assert(a4[1, 1, 1, 1] == 9)
        \\
    );
}

test "arrays: fill sets every slot; len is the first dimension" {
    try agreeOk(
        \\func main():
        \\    var row = new array(double, 4)
        \\    row.fill(1.5)
        \\    assert(row[0] == 1.5 and row[3] == 1.5)
        \\    assert(len(row) == 4)
        \\    var grid = new array(long, 3, 5)
        \\    assert(len(grid) == 3)
        \\
    );
}

test "arrays: rank-1 sort, reverse, find, contains" {
    try agreeOk(
        \\func main():
        \\    var row = new array(long, 4)
        \\    row[0] = 3
        \\    row[1] = 1
        \\    row[2] = 4
        \\    row[3] = 2
        \\    row.sort()
        \\    assert(row[0] == 1 and row[3] == 4)
        \\    assert(row.find(4) == 3)
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
        \\    x: long
        \\    y: long
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
        \\    n: long
        \\
        \\struct Outer:
        \\    inner: Inner
        \\    tag: long
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
        \\    dummy: long
        \\
        \\    func square(n: long) -> long:
        \\        return n * n
        \\
        \\    func hypot_sq(a: long, b: long) -> long:
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
        \\    var moved = give original
        \\    moved.append(4)
        \\    assert(len(moved) == 4)
        \\    assert(moved[3] == 4)
        \\
    );
}

test "ownership: copy is a deep, independent duplicate" {
    try agreeOk(
        \\func main():
        \\    var source = [1, 2, 3]
        \\    var dup = copy source
        \\    dup.append(4)
        \\    assert(len(dup) == 4)
        \\    assert(len(source) == 3)
        \\    source[0] = 99
        \\    assert(dup[0] == 1)
        \\
    );
}

test "ownership: reassigning an owning var frees the old object with no leak" {
    try agreeOk(
        \\func main():
        \\    var b = new builder()
        \\    b.append("first")
        \\    b = new builder()
        \\    b.append("second")
        \\    assert(b.build() == "second")
        \\
    );
}

test "ownership: a late-declared object slot can be filled and used" {
    try agreeOk(
        \\func main():
        \\    var xs: list(long)
        \\    xs = [7, 8, 9]
        \\    assert(len(xs) == 3)
        \\    xs.append(10)
        \\    assert(xs[3] == 10)
        \\
    );
}

test "ownership: return moves an object out of a function" {
    try agreeOk(
        \\func make() -> list(long):
        \\    var xs = new list(long)
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
        \\func total(xs: list(long)) -> long:
        \\    var sum: long = 0
        \\    for x in xs:
        \\        sum = sum + x
        \\    return sum
        \\
        \\func main():
        \\    var xs: list(long) = [1, 2, 3, 4]
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
        \\    x: long
        \\    y: long
        \\    z: long
        \\
        \\func main():
        \\    var n: long
        \\    assert(n == 0)
        \\    var f: double
        \\    assert(f == 0.0)
        \\    var flag: bool
        \\    assert(not flag)
        \\    var s: string
        \\    assert(s == "")
        \\    assert(len(s) == 0)
        \\    var v: Vec3
        \\    assert(v.x == 0 and v.y == 0 and v.z == 0)
        \\
    );
}

test "a late var can be assigned after a branch decides its value" {
    try agreeOk(
        \\func pick(flag: bool) -> long:
        \\    var out: long
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
        \\let limit = 3 * 4
        \\let ratio = 1.0 / 4.0
        \\let enabled = true and not false
        \\let prefix = "id_"
        \\
        \\func label(n: long) -> string:
        \\    return prefix + string(n)
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
        \\let base = 10
        \\let doubled = base * 2
        \\let quadrupled = doubled * 2
        \\let name = "core"
        \\let full = name + "!"
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
        \\func passthrough(n: long?) -> long?:
        \\    return n
        \\
        \\func text(t: string?) -> string?:
        \\    return t
        \\
        \\func main():
        \\    var n: long? = none
        \\    assert(n == none)
        \\    assert(not (n != none))
        \\    n = 7
        \\    # Through a call the narrowing is gone and the question is
        \\    # a real one again.
        \\    assert(passthrough(n) != none)
        \\    assert(not (passthrough(n) == none))
        \\    var t: string? = "hi"
        \\    assert(text(t) != none)
        \\    t = none
        \\    assert(t == none)
        \\
    );
}

test "narrowing: a tested name is its payload inside the branch, and both branches see it" {
    try agreeOk(
        \\func main():
        \\    let n = parse_int("41")
        \\    var seen: long = 0
        \\    if n != none:
        \\        seen = n + 1
        \\    else:
        \\        seen = 0 - 1
        \\    assert(seen == 42)
        \\
        \\    let bad = parse_int("x")
        \\    var other: long = 0
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
        \\func doubled(text: string) -> long:
        \\    let n = parse_int(text)
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
        \\    var total: long = 0
        \\    for text in inputs:
        \\        let n = parse_int(text)
        \\        if n == none:
        \\            continue
        \\        total = total + n
        \\    assert(total == 4)
        \\
        \\    var index = 0
        \\    var first: long = 0
        \\    while index < len(inputs):
        \\        let n = parse_int(inputs[index])
        \\        index = index + 1
        \\        if n == none:
        \\            break
        \\        first = first + n
        \\    assert(first == 1)
        \\    free(inputs)
        \\
    );
}

test "narrowing: and carries the test into the rest of the condition" {
    try agreeOk(
        \\func main():
        \\    let n = parse_int("5")
        \\    var hit = false
        \\    if n != none and n > 3:
        \\        hit = true
        \\    assert(hit)
        \\
        \\    let bad = parse_int("x")
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
        \\    var n: long? = none
        \\    n = 3
        \\    assert(n * 2 == 6)
        \\    var xs: list(long)? = none
        \\    xs = new list(long)
        \\    xs.append(4)
        \\    assert(len(xs) == 1)
        \\    free(xs)
        \\
    );
}

test "narrowing: a while condition narrows its body" {
    try agreeOk(
        \\func main():
        \\    var countdown: long? = 3
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
        \\    assert((parse_int("8") else 0) == 8)
        \\    assert((parse_int("x") else 0) == 0)
        \\    # right-associative: the first that is there wins.
        \\    assert((parse_int("x") else parse_int("9") else 0) == 9)
        \\    assert((parse_int("x") else parse_int("y") else 3) == 3)
        \\    # `else` binds tighter than comparison and looser than +.
        \\    assert((parse_int("x") else 2 + 3) == 5)
        \\    assert(((parse_int("x") else 1) == 1) == true)
        \\
    );
}

test "else runs its fallback only when the value is absent" {
    try agreeOk(
        \\func note(log: builder, mark: string) -> long:
        \\    log.append(mark)
        \\    return 0
        \\
        \\func main():
        \\    let log = new builder
        \\    assert((parse_int("1") else note(log, "a")) == 1)
        \\    assert((parse_int("x") else note(log, "b")) == 0)
        \\    assert(log.build() == "b")
        \\    free(log)
        \\
    );
}

test "x else trap is the assert-unwrap" {
    try agreeOk(
        \\func main():
        \\    let n = parse_int("12") else trap("unreachable")
        \\    assert(n == 12)
        \\
    );
    try agreeTrap(
        \\func main():
        \\    var text = "not a number"
        \\    let n = parse_int(text) else trap("bad input")
        \\    assert(n == 0)
        \\
    , .explicit_trap);
}

test "an optional crosses a call, a return, and a struct field" {
    try agreeOk(
        \\struct Setting:
        \\    name: string
        \\    limit: long?
        \\
        \\func describe(limit: long?) -> string:
        \\    if limit == none:
        \\        return "unlimited"
        \\    return string(limit)
        \\
        \\func lookup(found: bool) -> long?:
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
        \\    value: long
        \\    next: Node?
        \\
        \\func total(head: Node?) -> long:
        \\    var sum: long = 0
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
        \\    var n: long? = none
        \\    n = 10
        \\    n += 5
        \\    n *= 2
        \\    assert(n == 30)
        \\    var s: string? = "a"
        \\    s += "b"
        \\    assert(s == "ab")
        \\
    );
}

test "absence survives a round trip through a struct field and a var" {
    try agreeOk(
        \\struct Slot:
        \\    held: string?
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
// Runtime traps: one program per stable TrapCode
// ---------------------------------------------------------------------------

// Checked arithmetic exists at both arithmetic widths and traps with
// one code (docs/TYPES.md §4).  Each of the three overflows below is
// therefore written twice, at 2^63 and at 2^31 — because a check
// hard-coded to one width is exactly the bug these pairs exist to
// catch, and the `int` half is the one ordinary code can reach.

test "trap: integer overflow on addition" {
    try agreeTrap(
        \\func main():
        \\    var x: long = 9223372036854775807
        \\    x = x + 1
        \\
    , .integer_overflow);
    try agreeTrap(
        \\func main():
        \\    var x: int = 2147483647
        \\    x = x + 1
        \\
    , .integer_overflow);
}

test "trap: integer overflow negating the minimum" {
    try agreeTrap(
        \\func main():
        \\    var n: long = 0 - 9223372036854775807
        \\    n = n - 1
        \\    let bad = 0 - n
        \\
    , .integer_overflow);
    try agreeTrap(
        \\func main():
        \\    var n: int = 0 - 2147483647
        \\    n = n - 1
        \\    let bad = 0 - n
        \\
    , .integer_overflow);
}

test "trap: integer overflow taking abs of the minimum" {
    try agreeTrap(
        \\func main():
        \\    var n: long = 0 - 9223372036854775807
        \\    n = n - 1
        \\    let bad = abs(n)
        \\
    , .integer_overflow);
    try agreeTrap(
        \\func main():
        \\    var n: int = 0 - 2147483647
        \\    n = n - 1
        \\    let bad = abs(n)
        \\
    , .integer_overflow);
}

test "trap: integer overflow multiplying, at the width that reaches it first" {
    // 46,341 squared is past 2^31 — the boundary docs/TYPES.md §4
    // says out loud that ordinary code reaches, and the reason `int`
    // is a type you ask for rather than the one arithmetic defaults
    // to when it has a `long` in it.
    try agreeTrap(
        \\func main():
        \\    var n: int = 46341
        \\    let bad = n * n
        \\
    , .integer_overflow);
    // And the same program one rung up, where it simply computes.
    try agreeOk(
        \\func main():
        \\    var n: long = 46341
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

test "trap: float-to-int conversion out of range" {
    try agreeTrap(
        \\func main():
        \\    var big = 1.0
        \\    while big < 1.0e30:
        \\        big = big * 10.0
        \\    let bad = long(big)
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
        \\    var grid = new array(long, 2, 3)
        \\    var row = 1
        \\    var column = 2
        \\    grid[row, column] = 7
        \\    assert(grid[1, 2] == 7)
        \\
    );
    try agreeTrap(
        \\func main():
        \\    var grid = new array(long, 2, 3)
        \\    var row = 2
        \\    let bad = grid[row, 0]
        \\
    , .index_bounds);
    try agreeTrap(
        \\func main():
        \\    var grid = new array(long, 2, 3)
        \\    var column = 3
        \\    let bad = grid[0, column]
        \\
    , .index_bounds);
    try agreeTrap(
        \\func main():
        \\    var grid = new array(long, 2, 3)
        \\    var below = -1
        \\    let bad = grid[0, below]
        \\
    , .index_bounds);
}

test "bounds: a map answers for a key it holds and traps for one it does not" {
    try agreeOk(
        \\func main():
        \\    var m = new map(string, long)
        \\    m["a"] = 1
        \\    assert(m["a"] == 1)
        \\    assert(m.has("a"))
        \\    assert(not m.has("b"))
        \\    assert(m.get("b", 9) == 9)
        \\    m.remove("b")
        \\    assert(len(m) == 1)
        \\
    );
    try agreeTrap(
        \\func main():
        \\    var m = new map(string, long)
        \\    m["a"] = 1
        \\    var wanted = "b"
        \\    let bad = m[wanted]
        \\
    , .key_missing);
}

test "bounds: a string slice is checked at its length and on its boundaries" {
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
    , .string_bounds);
    try agreeTrap(
        \\func main():
        \\    var s = "abc"
        \\    var past = 3
        \\    let bad = s.byte_at(past)
        \\
    , .string_bounds);
    try agreeTrap(
        \\func main():
        \\    var s = "é"
        \\    var middle = 1
        \\    let bad = s[0:middle]
        \\
    , .string_boundary);
}

test "trap: array index out of bounds" {
    try agreeTrap(
        \\func main():
        \\    var grid = new array(long, 2, 2)
        \\    grid[2, 0] = 1
        \\
    , .index_bounds);
}

test "trap: missing map key" {
    try agreeTrap(
        \\func main():
        \\    var m = new map(string, long)
        \\    m["present"] = 1
        \\    let bad = m["absent"]
        \\
    , .key_missing);
}

test "trap: popping an empty list" {
    try agreeTrap(
        \\func main():
        \\    var xs = new list(long)
        \\    let bad = xs.pop()
        \\
    , .empty_collection);
}

test "trap: string index out of bounds" {
    try agreeTrap(
        \\func main():
        \\    var s = "ab"
        \\    let bad = s[0:9]
        \\
    , .string_bounds);
}

test "trap: byte_at past the end of a string" {
    try agreeTrap(
        \\func main():
        \\    var s = "ab"
        \\    let bad = s.byte_at(5)
        \\
    , .string_bounds);
}

test "trap: slicing through the middle of a UTF-8 character" {
    try agreeTrap(
        \\func main():
        \\    var s = "🙂"
        \\    let bad = s[0:1]
        \\
    , .string_boundary);
}

test "trap: use after free" {
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2]
        \\    let view = xs
        \\    free(xs)
        \\    let bad = view[0]
        \\
    , .use_after_free);
}

test "trap: using an unfilled late object slot" {
    try agreeTrap(
        \\func main():
        \\    var xs: list(long)
        \\    let bad = len(xs)
        \\
    , .null_object);
}

test "trap: unfilled object slot inside an array of objects" {
    try agreeTrap(
        \\func main():
        \\    var cells = new array(list(long), 2)
        \\    cells[0].append(1)
        \\
    , .null_object);
}

test "trap: chr of a codepoint beyond Unicode's range" {
    try agreeTrap(
        \\func main():
        \\    var code = 11141111
        \\    let bad = chr(code)
        \\
    , .bad_codepoint);
}

test "trap: ord of an empty string" {
    try agreeTrap(
        \\func main():
        \\    var s = ""
        \\    let bad = ord(s)
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
/// to carry them: the lexer's escape set is `\n \t \\ \"` and nothing
/// else, so a codepoint above ASCII arrives as itself.
const smiley = "\xF0\x9F\x99\x82";

test "structs: a smooth pointer transform computes exactly" {
    try agreeOk(
        \\struct Point:
        \\    x: double
        \\    y: double
        \\
        \\func smooth(current: Point, target: Point, amount: double) -> Point:
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
        \\    func twice(value: long) -> long:
        \\        return value * 2
        \\
        \\    func plus(left: long, right: long) -> long:
        \\        return left + right
        \\
        \\func main():
        \\    assert(Math.twice(Math.plus(3, 4)) == 14)
        \\
    );
}

test "loops, recursion, strings, and builtins compute" {
    try agreeOk(
        \\func factorial(value: long) -> long:
        \\    if value <= 1:
        \\        return 1
        \\    return value * factorial(value - 1)
        \\
        \\func main():
        \\    var total: long = 0
        \\    for index in range(1, 11):
        \\        total = total + index
        \\    assert(total == 55)
        \\    assert(factorial(10) == 3628800)
        \\    assert("sum " + "of ten" == "sum of ten")
        \\    assert(min(clamp(total, 0, 40), abs(-3)) == 3)
        \\
    );
}

test "checked string intrinsics slice and inspect UTF-8 bytes" {
    try agreeOk("func main():\n" ++
        "    let text = \"ab" ++ smiley ++ "cd\\nnext\"\n" ++
        "    assert(text[0:2] == \"ab\")\n" ++
        "    assert(text[2:6] == \"" ++ smiley ++ "\")\n" ++
        "    assert(text.byte_at(2) == 240)\n");
}

test "string intrinsics implement multiline UTF-8-safe edits" {
    try agreeOk("func continuation(byte: long) -> bool:\n" ++
        "    return byte >= 128 and byte < 192\n" ++
        "\n" ++
        "func previous(value: string, cursor: long) -> long:\n" ++
        "    var at = cursor - 1\n" ++
        "    while at > 0 and continuation(value.byte_at(at)):\n" ++
        "        at = at - 1\n" ++
        "    return at\n" ++
        "\n" ++
        "func inserted(text: string, cursor: long, added: string) -> string:\n" ++
        "    return text[0:cursor] + added + text[cursor:len(text)]\n" ++
        "\n" ++
        "func erased(text: string, cursor: long) -> string:\n" ++
        "    let before = previous(text, cursor)\n" ++
        "    return text[0:before] + text[cursor:len(text)]\n" ++
        "\n" ++
        "func main():\n" ++
        "    let original = \"A" ++ smiley ++ "\\nB\"\n" ++
        "    assert(inserted(original, 5, \"x\") == \"A" ++ smiley ++ "x\\nB\")\n" ++
        "    assert(erased(original, 5) == \"A\\nB\")\n" ++
        "    assert(previous(original, 5) == 1)\n");
}

test "checked string intrinsics trap on bounds and UTF-8 splits" {
    const text = "\"a" ++ smiley ++ "b\"";
    const cases = [_]struct { edit: []const u8, code: mir.TrapCode }{
        .{ .edit = "assert(len(" ++ text ++ "[-1:0]) == 0)", .code = .string_bounds },
        .{ .edit = "assert(len(" ++ text ++ "[0:7]) == 0)", .code = .string_bounds },
        .{ .edit = "assert(len(" ++ text ++ "[0:2]) == 0)", .code = .string_boundary },
        .{ .edit = "assert(" ++ text ++ ".byte_at(6) == 0)", .code = .string_bounds },
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
    // type until it lands, so the overflow at 2^63 says `long` and
    // the conversion out of a value only binary64 holds says `double`
    // (docs/TYPES.md §1).
    const cases = [_]struct { body: []const u8, code: mir.TrapCode }{
        .{ .body = "var n: long = 9223372036854775807\n    assert(n + 1 == 0)", .code = .integer_overflow },
        .{ .body = "var n: int = 2147483647\n    assert(n + 1 == 0)", .code = .integer_overflow },
        .{ .body = "assert(1 // (2 - 2) == 0)", .code = .divide_by_zero },
        .{ .body = "var big: double = 1.0e300\n    assert(long(big) == 0)", .code = .conversion_range },
        .{ .body = "var big: float = 1.0e30\n    assert(int(big) == 0)", .code = .conversion_range },
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
        \\func dive(depth: long) -> long:
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
        \\    free(mid)
        \\    free(xs)
        \\
    );
}

test "maps upsert, look up, and iterate keys in insertion order" {
    try agreeOk(
        \\func main():
        \\    var ages = new map(string, long)
        \\    ages["ada"] = 36
        \\    ages["alan"] = 41
        \\    ages["ada"] = 37
        \\    assert(len(ages) == 2)
        \\    assert(ages["ada"] == 37)
        \\    assert(ages.has("alan"))
        \\    var joined = new builder()
        \\    for key in ages:
        \\        joined.append(key)
        \\    assert(joined.build() == "adaalan")
        \\    ages.remove("alan")
        \\    assert(not ages.has("alan"))
        \\    ages.remove("ghost")
        \\    assert(len(ages) == 1)
        \\    free(ages)
        \\    free(joined)
        \\
    );
}

test "arrays are fixed, zeroed, multi-dimensional, and typed" {
    try agreeOk(
        \\func corner(grid: array(long, _, _)) -> long:
        \\    return grid[grid.dim(0) - 1, grid.dim(1) - 1]
        \\
        \\func main():
        \\    var grid = new array(long, 3, 4)
        \\    assert(grid.dim(0) == 3)
        \\    assert(grid.dim(1) == 4)
        \\    assert(len(grid) == 3)
        \\    assert(grid[2, 3] == 0)
        \\    grid[2, 3] = 7
        \\    assert(corner(grid) == 7)
        \\    var row = new array(double, 4)
        \\    row[0] = 2.5
        \\    var total: double = 0.0
        \\    for value in row:
        \\        total = total + value
        \\    assert(total == 2.5)
        \\    free(grid)
        \\    free(row)
        \\
    );
}

test "conversions: string, parse_int, parse_float, chr, ord over every kind" {
    try agreeOk(
        \\func main():
        \\    assert(string(42) == "42")
        \\    assert(string(-7) == "-7")
        \\    assert(string(true) == "true")
        \\    assert(string(2.5) == "2.5")
        \\    assert((parse_int("123") else 0) == 123)
        \\    assert((parse_int("-9") else 0) == 0 - 9)
        \\    assert((parse_float("2.5") else 0.0) == 2.5)
        \\    assert(parse_int("twelve") == none)
        \\    assert(chr(65) == "A")
        \\    assert(chr(955) == "λ")
        \\    assert(ord("λ") == 955)
        \\    assert(ord("A") == 65)
        \\
    );
}

test "structs and nested collections share objects by reference" {
    try agreeOk(
        \\struct Bag:
        \\    label: string
        \\    items: list(long)
        \\
        \\func main():
        \\    var inner: list(long) = [1, 2]
        \\    var bag = Bag(label = "first", items = give inner)
        \\    let same_bag = bag
        \\    same_bag.items.append(3)
        \\    assert(len(bag.items) == 3)
        \\    var nested = new list(list(long))
        \\    nested.append(copy bag.items)
        \\    nested[0].append(4)
        \\    assert(len(nested[0]) == 4)
        \\    assert(len(bag.items) == 3)
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
        \\    var xs: list(long) = []
        \\    let bad = xs.pop()
        \\
        , .code = .empty_collection },
        .{ .source =
        \\func main():
        \\    var m = new map(string, long)
        \\    let bad = m["ghost"]
        \\
        , .code = .key_missing },
        .{ .source =
        \\func main():
        \\    var xs = [1]
        \\    let view = xs
        \\    free(xs)
        \\    view.append(2)
        \\
        , .code = .use_after_free },
        .{ .source =
        \\func main():
        \\    var xs = [1]
        \\    let view = xs
        \\    free(xs)
        \\    let bad = view[0]
        \\
        , .code = .use_after_free },
        .{ .source =
        \\func main():
        \\    var cells = new array(list(long), 2)
        \\    cells[0].append(1)
        \\
        , .code = .null_object },
        .{ .source =
        \\func main():
        \\    let bad = chr(11141111)
        \\
        , .code = .bad_codepoint },
        .{ .source =
        \\func main():
        \\    var grid = new array(long, 2, 2)
        \\    grid[2, 0] = 1
        \\
        , .code = .index_bounds },
    };
    for (cases) |case| try agreeTrap(case.source, case.code);
}

test "S33: nothing leaks — scope ownership frees what free() used to" {
    try agreeOk(
        \\func main():
        \\    let kept = [1, 2, 3]
        \\    let copied = kept[0:2]
        \\    var released = new builder()
        \\    free(released)
        \\    assert(len(copied) == 2)
        \\
    );
}

test "string methods: search, case, trim, replace, repeat, split" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    let text = "  Hello, Luce World  "
        \\    let cleaned = text.trim()
        \\    assert(cleaned == "Hello, Luce World")
        \\    assert(cleaned.find("Luce") == 7)
        \\    assert(cleaned.find("zig") == -1)
        \\    assert(cleaned.contains("World"))
        \\    assert(cleaned.starts_with("Hello"))
        \\    assert(cleaned.ends_with("World"))
        \\    assert(cleaned.lower() == "hello, luce world")
        \\    assert(cleaned.upper() == "HELLO, LUCE WORLD")
        \\    assert(cleaned.replace("Luce", "brave") == "Hello, brave World")
        \\    assert("ab".repeat(3) == "ababab")
        \\    assert("x".repeat(0) == "")
        \\    assert("na".byte_at(0) == 110)
        \\    var words = cleaned.replace(",", "").split("")
        \\    assert(len(words) == 3)
        \\    assert(words[0] == "Hello")
        \\    var csv = "a;b;;c".split(";")
        \\    assert(len(csv) == 4)
        \\    assert(csv[2] == "")
        \\    assert(csv.join("|") == "a|b||c")
        \\    free(words)
        \\    free(csv)
        \\
    );
}

test "list and array methods: sort, reverse, find, contains, fill, clear" {
    try agreeOk(
        \\import std.strings
        \\
        \\func main():
        \\    var xs = [3, 1, 4, 1, 5]
        \\    xs.sort()
        \\    assert(xs[0] == 1)
        \\    assert(xs[4] == 5)
        \\    xs.reverse()
        \\    assert(xs[0] == 5)
        \\    assert(xs.find(4) == 1)
        \\    assert(xs.find(9) == -1)
        \\    assert(xs.contains(3))
        \\    assert(not xs.contains(9))
        \\    xs.clear()
        \\    assert(len(xs) == 0)
        \\    var names = ["cyan", "amber"]
        \\    names.sort()
        \\    assert(names[0] == "amber")
        \\    var row = new array(long, 4)
        \\    row.fill(7)
        \\    assert(row[3] == 7)
        \\    assert(row.contains(7))
        \\    row[1] = 2
        \\    row.sort()
        \\    assert(row[0] == 2)
        \\    var ages = new map(string, long)
        \\    ages["ada"] = 36
        \\    ages["alan"] = 41
        \\    var listed = ages.keys()
        \\    assert(listed.join(",") == "ada,alan")
        \\    ages.clear()
        \\    assert(len(ages) == 0)
        \\    free(xs)
        \\    free(names)
        \\    free(row)
        \\    free(ages)
        \\    free(listed)
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
        \\    var cells = new array(bool, 2, 2)
        \\    cells[0, 1] = a == b or a
        \\    let chosen = pick(a and b, a or b)
        \\    let pair = Flags(left = a or b, right = a and b)
        \\    var flags = [a or b, pair.left, cells[0, 1] and chosen]
        \\    flags.append(a or b)
        \\    let compared = (a or b) == (a and b)
        \\    let sliced = flags[0:len(flags)]
        \\    for index in range(0, len(sliced)):
        \\        let unused = sliced[index] or compared
        \\    free(sliced)
        \\    free(flags)
        \\    free(cells)
        \\
    );
}

test "file-scope constants fold every value kind" {
    try agreeOk(
        \\import std.strings
        \\
        \\let width = 80
        \\let tau = 2.0 * pi
        \\let pi = 3.14159
        \\let debug = not (width > 100)
        \\let greeting = "hello, " + "loom"
        \\let shout = greeting
        \\let half_width = width // 2 - 1
        \\let truncated = long(tau)
        \\let widened = double(width)
        \\let roomy = width >= 80 and tau > 6.0
        \\
        \\func main():
        \\    assert(width == 80)
        \\    assert(half_width == 39)
        \\    assert(tau > 6.28 and tau < 6.29)
        \\    assert(debug)
        \\    assert(greeting == "hello, loom")
        \\    assert(shout.upper() == "HELLO, LOOM")
        \\    assert(truncated == 6)
        \\    assert(widened == 80.0)
        \\    assert(roomy)
        \\    var xs = [width, half_width]
        \\    assert(xs[0] + xs[1] == 119)
        \\
    );
}

test "struct constants: the Theme case" {
    try agreeOk(
        \\struct Theme:
        \\    keyword: long
        \\    comment: long
        \\    bold: bool
        \\
        \\let theme = Theme(keyword = 114, comment = 238, bold = true)
        \\let accent = theme.keyword + 1
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
        \\func divide(a: long, b: long) -> long:
        \\    return a // b
        \\
        \\func ratio(n: long) -> long:
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
        \\func boom() -> long:
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
        \\func spiral(n: long) -> long:
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
// The storage widths: `byte`, `short`, `half` (docs/TYPES.md step 5)
// ---------------------------------------------------------------------------

test "storage: the three widths hold what the ladder says they hold" {
    try agreeOk(
        \\func main():
        \\    let low: byte = 0
        \\    let high: byte = 255
        \\    let bottom: short = -32768
        \\    let top: short = 32767
        \\    assert(low == 0)
        \\    assert(high == 255)
        \\    assert(bottom == -32768)
        \\    assert(top == 32767)
        \\    assert(string(high) == "255")
        \\    assert(string(bottom) == "-32768")
        \\
    );
}

test "storage: an operator promotes, so nothing wraps at 8 or 16 bits" {
    // D5's whole point: `byte + byte` is an `int`, so 255 + 1 is 256
    // and not 0.  There is no arithmetic at a storage width to
    // overflow, which is why `byte` needs no checked arithmetic.
    try agreeOk(
        \\func main():
        \\    var a: byte = 255
        \\    var b: byte = 1
        \\    assert(a + b == 256)
        \\    assert(a * a == 65025)
        \\    var s: short = 32767
        \\    assert(s + s == 65534)
        \\    var h: half = 0.5
        \\    assert(h + h == 1.0)
        \\    assert(h * 4.0 == 2.0)
        \\
    );
}

test "storage: a byte widens as a magnitude and a short as a sign" {
    // D4: a `byte`'s bits are read as a magnitude (`zext`), and every
    // other integer's carry a sign (`sext`).  128 is the value that
    // tells the two apart — as a signed 8-bit pattern it would be -128.
    try agreeOk(
        \\func main():
        \\    var b: byte = 128
        \\    var n: long = b
        \\    assert(n == 128)
        \\    assert(b > 127)
        \\    var s: short = -128
        \\    var m: long = s
        \\    assert(m == -128)
        \\    assert(s < 0)
        \\
    );
}

test "storage: byte_at answers a byte, and the high bytes stay positive" {
    // The §9 exception, and the reason it is one: a UTF-8 lead byte is
    // 0..255 on both engines and always has been, so every ordered
    // comparison against 128, 192 or 194 in the corpus keeps reading
    // the way it is written.
    try agreeOk(
        \\func main():
        \\    let text = "é"
        \\    assert(text.byte_at(0) == 195)
        \\    assert(text.byte_at(1) == 169)
        \\    assert(text.byte_at(0) >= 128)
        \\    assert(text.byte_at(0) < 224)
        \\    assert(string(text.byte_at(0)) == "195")
        \\    let plain = "hi"
        \\    assert(plain.find_byte(105, 0) == 1)
        \\    assert(plain.find_byte(plain.byte_at(0), 0) == 0)
        \\
    );
}

// -- conversions, both directions, at every boundary ------------------------

test "storage: narrowing to a byte keeps its range and traps outside it" {
    try agreeOk(
        \\func main():
        \\    assert(byte(0) == 0)
        \\    assert(byte(255) == 255)
        \\    assert(byte(254.6) == 255)
        \\    assert(byte(0.4) == 0)
        \\    assert(short(-32768) == -32768)
        \\    assert(short(32767) == 32767)
        \\    assert(int(byte(200)) == 200)
        \\    assert(long(short(-300)) == -300)
        \\
    );
}

test "storage: a byte reaches a float as a magnitude, not as a sign" {
    // The other half of D4, and the half an integer-to-integer test
    // cannot reach: a `byte` above 127 has its top bit set, so a
    // conversion that read the bits as signed would answer -56 for
    // 200 — and `double(b)` is the widening every mixed expression
    // inserts for itself.
    try agreeOk(
        \\func main():
        \\    var high: byte = 200
        \\    assert(double(high) == 200.0)
        \\    assert(float(high) == 200.0)
        \\    assert(high * 1.0 == 200.0)
        \\    assert(double(byte(255)) == 255.0)
        \\    var top: byte = 128
        \\    assert(double(top) == 128.0)
        \\    var widened: double = top
        \\    assert(widened == 128.0)
        \\
    );
}

test "storage: byte(256) traps rather than wrapping to zero" {
    try agreeTrap(
        \\func main():
        \\    var over: long = 256
        \\    var narrowed = byte(over)
        \\    print(string(narrowed))
        \\
    , .conversion_range);
}

test "storage: byte(-1) traps rather than becoming 255" {
    try agreeTrap(
        \\func main():
        \\    var under: long = -1
        \\    var narrowed = byte(under)
        \\    print(string(narrowed))
        \\
    , .conversion_range);
}

test "storage: short(32768) and short(-32769) both trap" {
    try agreeTrap(
        \\func main():
        \\    var over: long = 32768
        \\    var narrowed = short(over)
        \\    print(string(narrowed))
        \\
    , .conversion_range);
    try agreeTrap(
        \\func main():
        \\    var under: long = -32769
        \\    var narrowed = short(under)
        \\    print(string(narrowed))
        \\
    , .conversion_range);
}

test "storage: a float landing on a byte is checked after it rounds" {
    // The range check runs on what rounding produced, so 255.5 rounds
    // to 256 and is refused rather than truncated back into range.
    try agreeTrap(
        \\func main():
        \\    var edge: double = 255.5
        \\    var narrowed = byte(edge)
        \\    print(string(narrowed))
        \\
    , .conversion_range);
}

// -- half: binary16, bit-exact on both engines ------------------------------

test "half: the boundary values round-trip bit-exactly" {
    // 65504 is the largest finite binary16; 2^-14 is the smallest
    // normal and 2^-24 the smallest subnormal.  The last assert is
    // §3's "shortest representation that round-trips *at its own
    // width*" caught in the act: 65504 prints as "65500", because
    // binary16 has no other value nearer to 65500 and four digits is
    // all it takes to name this one.
    try agreeOk(
        \\func main():
        \\    let biggest: half = 65504.0
        \\    let smallest_normal: half = 0.00006103515625
        \\    let smallest_subnormal: half = 0.000000059604644775390625
        \\    assert(double(biggest) == 65504.0)
        \\    assert(double(smallest_normal) == 0.00006103515625)
        \\    assert(double(smallest_subnormal) == 0.000000059604644775390625)
        \\    assert(string(biggest) == "65500")
        \\
    );
}

test "half: integers are exact to 2048 and step by two after it" {
    try agreeOk(
        \\func main():
        \\    assert(double(half(2048.0)) == 2048.0)
        \\    assert(double(half(2049.0)) == 2048.0)
        \\    assert(double(half(2050.0)) == 2050.0)
        \\    assert(double(half(1025.0)) == 1025.0)
        \\
    );
}

test "half: overflow reaches infinity rather than trapping" {
    // Float to narrower float is IEEE and does not trap (§3), so
    // 1e300 lands on `inf` — and `half` acquires one far more easily
    // than `double` does, which is the whole reason the language does
    // not grow a second story about infinity for it.
    try agreeOk(
        \\func main():
        \\    var big: double = 1.0e300
        \\    var over = half(big)
        \\    assert(double(over) > 65504.0)
        \\    assert(string(over) == "inf")
        \\    var negative = half(-big)
        \\    assert(string(negative) == "-inf")
        \\
    );
}

test "half: rounds to nearest, ties to even" {
    // 2049 sits exactly between 2048 and 2050 at binary16; ties to
    // even takes 2048.  2051 sits between 2050 and 2052 and takes
    // 2052 for the same reason.
    try agreeOk(
        \\func main():
        \\    var a: double = 2049.0
        \\    var b: double = 2051.0
        \\    assert(double(half(a)) == 2048.0)
        \\    assert(double(half(b)) == 2052.0)
        \\
    );
}

test "half: double to half rounds once, not twice through binary32" {
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
        \\    var just_above: double = 1.0004882821813226
        \\    assert(double(half(just_above)) == 1.0009765625)
        \\    var tie: double = 1.00048828125
        \\    assert(double(half(tie)) == 1.0)
        \\    var exact: double = 1.0009765625
        \\    assert(double(half(exact)) == 1.0009765625)
        \\
    );
}

test "half: a non-finite half landing on an integer traps" {
    // The bound `int` names is not finite at binary16, so the check
    // that catches this is the one that includes its bound rather than
    // excluding it.
    try agreeTrap(
        \\func main():
        \\    var big: double = 1.0e300
        \\    var over = half(big)
        \\    var narrowed = int(over)
        \\    print(string(narrowed))
        \\
    , .conversion_range);
}

// -- array(byte, n): one byte an element ------------------------------------

test "storage: an array of bytes stores and reads every value 0..255" {
    try agreeOk(
        \\func main():
        \\    var cells = new array(byte, 256)
        \\    var at = 0
        \\    while at < 256:
        \\        cells[at] = byte(at)
        \\        at += 1
        \\    assert(cells[0] == 0)
        \\    assert(cells[128] == 128)
        \\    assert(cells[255] == 255)
        \\    var total = 0
        \\    at = 0
        \\    while at < 256:
        \\        total += cells[at]
        \\        at += 1
        \\    assert(total == 32640)
        \\
    );
}

test "storage: arrays of short and half keep their own widths" {
    try agreeOk(
        \\func main():
        \\    var shorts = new array(short, 4)
        \\    shorts[0] = -32768
        \\    shorts[3] = 32767
        \\    assert(shorts[0] == -32768)
        \\    assert(shorts[3] == 32767)
        \\    assert(shorts[1] == 0)
        \\    var halves = new array(half, 3)
        \\    halves[0] = 0.5
        \\    halves[1] = 65504.0
        \\    assert(double(halves[0]) == 0.5)
        \\    assert(double(halves[1]) == 65504.0)
        \\    assert(halves[0] + halves[0] == 1.0)
        \\
    );
}

test "storage: a store past a byte element's range traps" {
    try agreeTrap(
        \\func main():
        \\    var cells = new array(byte, 4)
        \\    var over: long = 300
        \\    cells[0] = byte(over)
        \\    print(string(cells[0]))
        \\
    , .conversion_range);
}

test "storage: a list of bytes round-trips through the boxed path" {
    // `List` stays boxed (§6) — this is the proof that a `byte`
    // survives being boxed and read back, which is the path a list
    // element takes and an array element does not.
    try agreeOk(
        \\func main():
        \\    var xs = new list(byte)
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

test "storage: a struct field may be a storage width" {
    try agreeOk(
        \\struct Pixel:
        \\    red: byte
        \\    green: byte
        \\    blue: byte
        \\
        \\func main():
        \\    let p = Pixel(red = 255, green = 128, blue = 0)
        \\    assert(p.red == 255)
        \\    assert(p.green == 128)
        \\    assert(p.blue == 0)
        \\    assert(p.red + p.green + p.blue == 383)
        \\
    );
}

test "storage: a parameter and a return may be a storage width" {
    try agreeOk(
        \\func lighten(c: byte) -> byte:
        \\    if c > 200:
        \\        return 255
        \\    return byte(c + 40)
        \\
        \\func main():
        \\    assert(lighten(10) == 50)
        \\    assert(lighten(255) == 255)
        \\    assert(lighten(byte(201)) == 255)
        \\
    );
}
