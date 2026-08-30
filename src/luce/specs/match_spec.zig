//! Value matches: `match` over the integers, `char`, `str`, and
//! `bool`, with literal arms, multi-value arms, and inclusive
//! `low .. high` ranges for the ordered scalars.
//!
//! Every claim runs on the compiled path and the interpreter oracle
//! and the two are compared (`specs/agree.zig`).  The enum and union
//! halves of `match` live in enums_spec and union_spec; this file is
//! the third scrutinee family — the one whose cases have no names.

const agree = @import("agree.zig");

test "integers: exact arms, multi-value arms, and first-match-wins" {
    try agree.ok(
        \\func label(code: i64) -> str:
        \\    match code:
        \\        0:
        \\            return "zero"
        \\        1, 2:
        \\            return "one-or-two"
        \\        else:
        \\            return "other"
        \\
        \\func main():
        \\    assert(label(0) == "zero")
        \\    assert(label(1) == "one-or-two")
        \\    assert(label(2) == "one-or-two")
        \\    assert(label(3) == "other")
        \\    assert(label(-1) == "other")
        \\
    );
}

test "integers: ranges are inclusive at both ends, and overlap goes to the first arm" {
    try agree.ok(
        \\func band(value: i64) -> str:
        \\    match value:
        \\        0..9:
        \\            return "digit"
        \\        9..19:
        \\            return "teens"
        \\        else:
        \\            return "large"
        \\
        \\func main():
        \\    assert(band(0) == "digit")
        \\    assert(band(9) == "digit")
        \\    assert(band(10) == "teens")
        \\    assert(band(19) == "teens")
        \\    assert(band(20) == "large")
        \\
    );
}

test "integers: negative literals and negative ranges match" {
    try agree.ok(
        \\func side(value: i64) -> str:
        \\    match value:
        \\        -5:
        \\            return "minus five"
        \\        -4..-1:
        \\            return "small negative"
        \\        0:
        \\            return "zero"
        \\        else:
        \\            return "positive or far"
        \\
        \\func main():
        \\    assert(side(-5) == "minus five")
        \\    assert(side(-4) == "small negative")
        \\    assert(side(-1) == "small negative")
        \\    assert(side(0) == "zero")
        \\    assert(side(1) == "positive or far")
        \\    assert(side(-6) == "positive or far")
        \\
    );
}

test "integers: every explicit width dispatches, u64's top half included" {
    try agree.ok(
        \\func tiny(value: u8) -> str:
        \\    match value:
        \\        0..127:
        \\            return "low"
        \\        else:
        \\            return "high"
        \\
        \\func wide(value: u64) -> str:
        \\    match value:
        \\        18446744073709551615:
        \\            return "max"
        \\        else:
        \\            return "smaller"
        \\
        \\func main():
        \\    assert(tiny(u8(0)) == "low")
        \\    assert(tiny(u8(127)) == "low")
        \\    assert(tiny(u8(128)) == "high")
        \\    assert(wide(u64(18446744073709551615)) == "max")
        \\    assert(wide(u64(7)) == "smaller")
        \\
    );
}

test "char: ranges cover the scalar order, and an arm mixes ranges with exacts" {
    try agree.ok(
        \\func kind(c: char) -> str:
        \\    match c:
        \\        'a'..'z', 'A'..'Z':
        \\            return "letter"
        \\        '0'..'9':
        \\            return "digit"
        \\        ' ', '\t':
        \\            return "blank"
        \\        else:
        \\            return "other"
        \\
        \\func main():
        \\    assert(kind('a') == "letter")
        \\    assert(kind('z') == "letter")
        \\    assert(kind('Q') == "letter")
        \\    assert(kind('5') == "digit")
        \\    assert(kind(' ') == "blank")
        \\    assert(kind('\t') == "blank")
        \\    assert(kind('!') == "other")
        \\    assert(kind('λ') == "other")
        \\
    );
}

test "str: exact and multi-value arms compare whole text" {
    try agree.ok(
        \\func answer(word: str) -> i64:
        \\    match word:
        \\        "yes", "y":
        \\            return 1
        \\        "no":
        \\            return 0
        \\        "":
        \\            return -2
        \\        else:
        \\            return -1
        \\
        \\func main():
        \\    assert(answer("yes") == 1)
        \\    assert(answer("y") == 1)
        \\    assert(answer("no") == 0)
        \\    assert(answer("") == -2)
        \\    assert(answer("Yes") == -1)
        \\    assert(answer("yes ") == -1)
        \\
    );
}

test "bool: true and false arms are exhaustive, so no else is needed" {
    try agree.ok(
        \\func flag(b: bool) -> str:
        \\    match b:
        \\        true:
        \\            return "on"
        \\        false:
        \\            return "off"
        \\
        \\func main():
        \\    assert(flag(true) == "on")
        \\    assert(flag(false) == "off")
        \\
    );
}

test "arms are statements: they assign outer locals and leave early" {
    try agree.ok(
        \\func main():
        \\    var total = 0
        \\    var report = ""
        \\    for value in [1, 5, 12, 40]:
        \\        match value:
        \\            1, 2:
        \\                total += value
        \\            3..20:
        \\                total += value * 10
        \\                report += "banded "
        \\            else:
        \\                continue
        \\        report += "counted "
        \\    assert(total == 171)
        \\    assert(report == "counted banded counted banded counted ")
        \\
    );
}

test "a folded constant is a literal the compiler can read" {
    try agree.ok(
        \\let limit = 10
        \\
        \\func banded(value: i64) -> str:
        \\    match value:
        \\        limit:
        \\            return "at the limit"
        \\        else:
        \\            return "elsewhere"
        \\
        \\func main():
        \\    assert(banded(10) == "at the limit")
        \\    assert(banded(9) == "elsewhere")
        \\
    );
}

test "constants stand as patterns: exact, listed, and as range endpoints" {
    try agree.ok(
        \\let zero: char = '0'
        \\let nine: char = '9'
        \\let comma: char = ','
        \\let colon: char = ':'
        \\
        \\func kind(c: char) -> str:
        \\    match c:
        \\        zero..nine:
        \\            return "digit"
        \\        comma, colon:
        \\            return "separator"
        \\        else:
        \\            return "other"
        \\
        \\func main():
        \\    assert(kind('0') == "digit")
        \\    assert(kind('5') == "digit")
        \\    assert(kind('9') == "digit")
        \\    assert(kind(',') == "separator")
        \\    assert(kind(':') == "separator")
        \\    assert(kind('x') == "other")
        \\
    );
}

test "the scrutinee is read once, before any arm runs" {
    try agree.ok(
        \\func counted(log: list[i64], value: i64) -> i64:
        \\    log.append(value)
        \\    return value
        \\
        \\func main():
        \\    var log: list[i64] = []
        \\    match counted(log, 7):
        \\        0..9:
        \\            assert(len(log) == 1)
        \\        else:
        \\            assert(false)
        \\    assert(len(log) == 1)
        \\
    );
}

test "pass is a no-op arm, so an arm can be deliberately empty" {
    // Without `pass` an arm that means "do nothing" had to write a
    // busy no-op like `x = x`; `pass` records nothing and falls
    // through, on both engines.
    try agree.prints(
        \\enum Signal:
        \\    go
        \\    stop
        \\    wait
        \\
        \\func main():
        \\    var log = ""
        \\    for s in [Signal.go, Signal.stop, Signal.wait, Signal.go]:
        \\        match s:
        \\            go:
        \\                log = log + "g"
        \\            stop:
        \\                log = log + "s"
        \\            wait:
        \\                pass
        \\    print(log)
        \\
    , "gsg\n");
}

test "pass fills any block, and control falls through it" {
    try agree.prints(
        \\func main():
        \\    var n = 0
        \\    if n == 0:
        \\        pass
        \\    else:
        \\        n = 1
        \\    while n < 3:
        \\        n = n + 1
        \\        if n == 2:
        \\            pass
        \\    print(str(n))
        \\
    , "3\n");
}
