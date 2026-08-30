//! `char`, scalar-indexed `str`, and immutable `bytes`.
//!
//! These are language values, not standard-library conveniences. Every
//! executable case therefore runs on the oracle and the compiled path and
//! compares output, traps, traces, and the final ARC census.

const std = @import("std");
const agree = @import("agree.zig");
const luce = @import("luce");

const testing = std.testing;

fn expectRejected(source: []const u8, code: []const u8) !void {
    var result = try luce.compile.compile(testing.allocator, source, .{});
    defer result.deinit();
    if (result == .success) {
        std.debug.print("expected {s}, but this compiled:\n{s}", .{ code, source });
        return error.TestUnexpectedResult;
    }
    for (0..result.failure.count()) |index| {
        if (std.mem.eql(u8, result.failure.at(index).?.code, code)) return;
    }
    const rendered = try result.failure.render(testing.allocator);
    defer testing.allocator.free(rendered);
    std.debug.print("expected {s}, got:\n{s}", .{ code, rendered });
    return error.TestUnexpectedResult;
}

fn expectCompiles(label: []const u8, source: []const u8) !void {
    var result = try luce.compile.compile(testing.allocator, source, .{});
    defer result.deinit();
    if (result == .success) return;
    const rendered = try result.failure.render(testing.allocator);
    defer testing.allocator.free(rendered);
    std.debug.print("{s} did not compile:\n{s}", .{ label, rendered });
    return error.TestUnexpectedResult;
}

test "character literals and conversions preserve Unicode scalar values" {
    try agree.prints(
        \\func echo(value: char) -> char:
        \\    return value
        \\
        \\func main():
        \\    let ascii: char = 'A'
        \\    let wave = '\u{1F44B}'
        \\    let line = '\n'
        \\    print(str(u32(ascii)))
        \\    print(str(wave))
        \\    print(str(u32(echo(char(u32(wave))))))
        \\    print(str(u32(line)))
        \\
    , "65\n👋\n128075\n10\n");
}

test "the complete Unicode scalar boundary converts and orders" {
    try agree.prints(
        \\func main():
        \\    var points = list[u32]()
        \\    points.append(u32(0))
        \\    points.append(u32(0xd7ff))
        \\    points.append(u32(0xe000))
        \\    points.append(u32(0x10ffff))
        \\    for point in points:
        \\        print(str(u32(char(point))))
        \\    print(str('A' < 'λ'))
        \\    print(str('λ' == char(u32('λ'))))
        \\
    , "0\n55295\n57344\n1114111\ntrue\ntrue\n");
}

test "a character literal is contextual over integer widths, and stays char without one" {
    // The #24 ruling under the constitution (Zig's 'a'-is-a-number,
    // arrived at through Luce's own contextual-literal rule): an
    // integer place takes the scalar when it fits — the comparison, the
    // range pair, the match arm, the annotated const — and a literal
    // with no integer context is exactly the char it always was.
    try agree.prints(
        \\let NEWLINE: u8 = '\n'
        \\
        \\func classify(c: u8) -> str:
        \\    if c == '"':
        \\        return "quote"
        \\    if c >= 'a' and c <= 'z':
        \\        return "letter"
        \\    match c:
        \\        '0' .. '9':
        \\            return "digit"
        \\        ' ':
        \\            return "space"
        \\        else:
        \\            return "other"
        \\
        \\func main():
        \\    print(classify(34))
        \\    print(classify(98))
        \\    print(classify(53))
        \\    print(classify(32))
        \\    print(str(NEWLINE))
        \\    let wide: char = 'é'
        \\    print(str(wide))
        \\    let plain = 'q'
        \\    print(str(plain))
        \\
    ,
        \\quote
        \\letter
        \\digit
        \\space
        \\10
        \\é
        \\q
        \\
    );
}

test "a character literal that does not fit its integer place is refused" {
    try expectRejected(
        \\func main():
        \\    let wide: u8 = '€'
        \\
    , "luce.sema.literal");
}

test "character escapes cover quotes slashes and scalar zero" {
    try agree.prints(
        \\func main():
        \\    print(str(u32('\'')))
        \\    print(str(u32('\\')))
        \\    print(str(u32('\"')))
        \\    print(str(u32('\u{0}')))
        \\
    , "39\n92\n34\n0\n");
}

test "characters retain their type in optionals lists arrays and structs" {
    try agree.prints(
        \\struct Mark:
        \\    let value: char
        \\    let fallback: char?
        \\
        \\func main():
        \\    let mark = Mark(value = 'λ', fallback = none)
        \\    var values = list[char]()
        \\    values.append(mark.value)
        \\    values.append('🙂')
        \\    var grid = array[char](2)
        \\    grid[0] = values[1]
        \\    grid[1] = mark.fallback else 'x'
        \\    print(str(values[0]) + str(grid[0]) + str(grid[1]))
        \\
    , "λ🙂x\n");
}

test "character containers sort at scalar order" {
    try agree.prints(
        \\func main():
        \\    var values = list[char]()
        \\    values.append('λ')
        \\    values.append('A')
        \\    values.append('🙂')
        \\    values.sort()
        \\    for value in values:
        \\        print(str(u32(value)))
        \\
    , "65\n955\n128578\n");
}

test "str length indexing slicing and iteration use scalar positions" {
    try agree.prints(
        \\func main():
        \\    let text = "A🙂é"
        \\    print(str(len(text)))
        \\    print(str(text[1]))
        \\    print(text[1:3])
        \\    var rebuilt = ""
        \\    for character in text:
        \\        rebuilt = rebuilt + "[" + str(character) + "]"
        \\    print(rebuilt)
        \\
    , "4\n🙂\n🙂e\n[A][🙂][e][́]\n");
}

test "bytes copy text lists and rank-one arrays without aliasing" {
    try agree.prints(
        \\func main():
        \\    let encoded = bytes("A🙂")
        \\    print(str(len(encoded)))
        \\    print(str(encoded[0]) + " " + str(encoded[1]) + " " + str(encoded[4]))
        \\    let middle = encoded[1:5]
        \\    print(parse_str(middle) else "not text")
        \\
        \\    var source = list[u8]()
        \\    source.append(u8(65))
        \\    source.append(u8(66))
        \\    let copied = bytes(source)
        \\    source[0] = u8(90)
        \\    print(parse_str(copied) else "not text")
        \\
        \\    var buffer = array[u8](3)
        \\    buffer[0] = u8(67)
        \\    buffer[1] = u8(68)
        \\    buffer[2] = u8(69)
        \\    print(parse_str(bytes(buffer)) else "not text")
        \\
    , "5\n65 240 130\n🙂\nAB\nCDE\n");
}

test "bytes concatenate compare slice and reject invalid UTF-8 as text" {
    try agree.prints(
        \\func main():
        \\    let first = bytes("ab")
        \\    let second = bytes("cd")
        \\    let joined = first + second
        \\    print(str(joined == bytes("abcd")))
        \\    print(str(first < second))
        \\    print(parse_str(joined[1:3]) else "not text")
        \\    var raw = list[u8]()
        \\    raw.append(u8(0xff))
        \\    raw.append(u8(0xfe))
        \\    print(parse_str(bytes(raw)) else "not text")
        \\
    , "true\ntrue\nbc\nnot text\n");
}

test "bytes iterate as u8 and preserve empty inline and outside storage" {
    try agree.prints(
        \\struct Packet:
        \\    let body: bytes
        \\    let mark: char
        \\
        \\func packet(body: bytes) -> Packet:
        \\    return Packet(body = body, mark = '✓')
        \\
        \\func main():
        \\    let empty = bytes("")
        \\    let short = bytes("ABC")
        \\    let long = bytes("abcdefghijklmnopqrstuvwxyz")
        \\    let held = packet(long)
        \\    var sum: i64 = 0
        \\    for byte in short:
        \\        sum += i64(byte)
        \\    print(str(len(empty)) + " " + str(sum))
        \\    print(parse_str(held.body) else "not text")
        \\    print(str(held.mark))
        \\
    , "0 198\nabcdefghijklmnopqrstuvwxyz\n✓\n");
}

test "char and bytes work through constants and transparent aliases" {
    try expectCompiles("char alias and constant",
        \\alias Rune = char
        \\let mark: Rune = 'λ'
        \\func main():
        \\    let copied = Rune(u32(mark))
        \\
    );
    try expectCompiles("bytes alias and constant",
        \\alias Data = bytes
        \\let payload: Data = bytes("hello")
        \\func main():
        \\    let copied: Data = Data(payload)
        \\
    );
    try agree.prints(
        \\alias Rune = char
        \\alias Data = bytes
        \\let mark: Rune = 'λ'
        \\let payload: Data = bytes("hello")
        \\
        \\func main():
        \\    let copied: Data = Data(payload)
        \\    print(str(Rune(u32(mark))))
        \\    print(parse_str(copied) else "not text")
        \\
    , "λ\nhello\n");
}

test "optional bytes retain and release their owned storage" {
    try agree.prints(
        \\func choose(value: bytes?) -> bytes:
        \\    return value else bytes("fallback")
        \\
        \\func main():
        \\    let present: bytes? = bytes("present beyond inline capacity")
        \\    let absent: bytes? = none
        \\    print(parse_str(choose(present)) else "not text")
        \\    print(parse_str(choose(absent)) else "not text")
        \\
    , "present beyond inline capacity\nfallback\n");
}

test "char conversion traps every non-scalar region" {
    for ([_]i64{ -1, 0xd800, 0xdfff, 0x110000 }) |invalid| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\func main():
            \\    var value: i64 = {d}
            \\    print(str(char(value)))
            \\
        , .{invalid});
        defer testing.allocator.free(source);
        try agree.trap(source, .bad_codepoint);
    }
}

test "malformed character literals are rejected by the character diagnostic" {
    for ([_][]const u8{ "''", "'ab'", "'\\u{}'", "'\\u{D800}'", "'\\q'" }) |literal| {
        const source = try std.fmt.allocPrint(
            testing.allocator,
            "func main():\n    let value = {s}\n",
            .{literal},
        );
        defer testing.allocator.free(source);
        var result = try luce.compile.compile(testing.allocator, source, .{});
        defer result.deinit();
        if (result == .success) {
            std.debug.print("malformed character literal compiled: {s}\n", .{literal});
            return error.TestUnexpectedResult;
        }
        var found = false;
        for (0..result.failure.count()) |index| {
            found = found or std.mem.eql(
                u8,
                result.failure.at(index).?.code,
                "luce.parse.char",
            );
        }
        try testing.expect(found);
    }
}

test "invalid char and bytes operations are rejected before lowering" {
    try expectRejected(
        "func main():\n    let value = 'a' + 'b'\n",
        "luce.sema.type",
    );
    try expectRejected(
        "func main():\n    let value = bytes(i64(1))\n",
        "luce.sema.convert",
    );
    // The literal spelling `i64('a')` stopped being this claim when
    // character literals became contextual (the scalar lands as the
    // integer before the conversion looks); the claim is about a
    // *runtime* char, which still has no conversion route.
    try expectRejected(
        "func main():\n    let held: char = 'a'\n    let value = i64(held)\n",
        "luce.sema.convert",
    );
    try expectRejected(
        "func main():\n    let value = parse_str(\"text\")\n",
        "luce.sema.type",
    );
    try expectRejected(
        "func main():\n    let data = bytes(\"abc\")\n    data[0] = u8(90)\n",
        "luce.sema.assign",
    );
}

// ---------------------------------------------------------------------------
// Indexing a str, and what it costs
// ---------------------------------------------------------------------------

test "str: indexing and slicing agree with a walk, whatever the encoding" {
    // A `str` is indexed by scalar and stored as UTF-8, and those two
    // only agree when every scalar is one byte.  Text that is all ASCII
    // is indexed directly and text that is not is walked
    // (`runtime.Encoding`), so the two paths must answer the same
    // question the same way — including at the boundary where a string
    // stops being ASCII, and for a slice, which inherits the claim.
    try agree.prints(
        \\func main():
        \\    let plain = "abcdefghijklmnopqrstuvwxyz0123456789"
        \\    let mixed = "abc" + "é" + "defghijklmnopqrstuvwxyz0123456789"
        \\    print(str(len(plain)) + " " + str(len(mixed)))
        \\    print(str(plain[0]) + str(plain[25]) + str(plain[35]))
        \\    print(str(mixed[2]) + str(mixed[3]) + str(mixed[4]))
        \\    print(plain[10:15] + "|" + mixed[2:6])
        \\    # A slice keeps whatever its source knew, so the same
        \\    # question asked of the piece must answer the same way.
        \\    let piece = mixed[3:9]
        \\    print(str(len(piece)) + " " + str(piece[0]) + str(piece[1]))
        \\    var walked = ""
        \\    for character in mixed:
        \\        walked = walked + str(character)
        \\    print(walked)
        \\    var indexed = ""
        \\    var at = 0
        \\    while at < len(mixed):
        \\        indexed = indexed + str(mixed[at])
        \\        at += 1
        \\    print(str(indexed == walked))
        \\
    ,
        \\36 37
        \\az9
        \\céd
        \\klmno|céde
        \\6 éd
        \\abcédefghijklmnopqrstuvwxyz0123456789
        \\true
        \\
    );
}

test "str: a growing string keeps answering the same as a fresh one" {
    // Concatenation is where a classification is cheapest to keep and
    // easiest to get wrong: two ASCII halves make an ASCII whole, and
    // anything else has to fall back rather than inherit the left side.
    try agree.prints(
        \\func main():
        \\    var built = ""
        \\    var n = 0
        \\    while n < 40:
        \\        built = built + "x"
        \\        n += 1
        \\    print(str(len(built)) + " " + str(built[39]))
        \\    let widened = built + "é"
        \\    print(str(len(widened)) + " " + str(widened[40]) + " " + str(widened[39]))
        \\    let narrowed = widened[0:41] + "y"
        \\    print(str(len(narrowed)) + " " + str(narrowed[41]) + " " + str(narrowed[40]))
        \\
    ,
        \\40 x
        \\41 é x
        \\42 y é
        \\
    );
}

test "str: an independent decoder agrees with every str operation, on both engines" {
    // 0.27 made an ASCII string index with a load instead of a walk, by
    // carrying what it knows about its own encoding through the
    // register, the box and the runtime.  The risk that buys is a claim
    // that is wrong: a string that says ASCII and is not would index
    // into the middle of a scalar, and would do it *quietly*.
    //
    // So the check does not reuse the thing it is checking.  It decodes
    // UTF-8 from `bytes` in Luce, by hand, and holds `len`, every
    // index, every slice and the iteration to what that decoder says —
    // over an empty string, each scalar width, the first multi-byte
    // scalar at thirty positions, thirty lengths either side of the
    // boundary where text stops living inside its value, slices of
    // slices, and all four ways two strings can be joined.
    //
    // Both engines run it, so a disagreement is also caught between the
    // path that carries the byte in a register and the path that does
    // not.
    try agree.prints(
        \\# An independent UTF-8 decoder, so the str path is checked against
        \\# something that does not share its implementation.
        \\func decode(raw: bytes) -> list[char]:
        \\    var out = list[char]()
        \\    var at = 0
        \\    while at < len(raw):
        \\        let lead = i64(raw[at])
        \\        var width = 1
        \\        var point = lead
        \\        if lead >= 240:
        \\            width = 4
        \\            point = lead - 240
        \\        elif lead >= 224:
        \\            width = 3
        \\            point = lead - 224
        \\        elif lead >= 192:
        \\            width = 2
        \\            point = lead - 192
        \\        var k = 1
        \\        while k < width:
        \\            point = point * 64 + (i64(raw[at + k]) - 128)
        \\            k += 1
        \\        out.append(char(point))
        \\        at += width
        \\    return out
        \\
        \\func rebuild(chars: list[char], from: i64, to: i64) -> str:
        \\    var out = ""
        \\    var at = from
        \\    while at < to:
        \\        out = out + str(chars[at])
        \\        at += 1
        \\    return out
        \\
        \\func check(sample: str, name: str):
        \\    let chars = decode(bytes(sample))
        \\    if len(sample) != len(chars):
        \\        trap("length disagrees for " + name)
        \\    var at = 0
        \\    while at < len(chars):
        \\        if sample[at] != chars[at]:
        \\            trap("index disagrees for " + name)
        \\        at += 1
        \\    var walked = list[char]()
        \\    for character in sample:
        \\        walked.append(character)
        \\    if len(walked) != len(chars):
        \\        trap("iteration length disagrees for " + name)
        \\    at = 0
        \\    while at < len(chars):
        \\        if walked[at] != chars[at]:
        \\            trap("iteration disagrees for " + name)
        \\        at += 1
        \\    var a = 0
        \\    while a <= len(chars):
        \\        var b = a
        \\        while b <= len(chars):
        \\            if sample[a:b] != rebuild(chars, a, b):
        \\                trap("slice disagrees for " + name)
        \\            b += 1
        \\        a += 1
        \\
        \\func main():
        \\    let ascii_short = "abc"
        \\    let ascii_long = "abcdefghijklmnopqrstuvwxyz0123456789"
        \\    check("", "empty")
        \\    check(ascii_short, "ascii short")
        \\    check(ascii_long, "ascii long")
        \\    check("é", "one two-byte")
        \\    check("€", "one three-byte")
        \\    check("👋", "one four-byte")
        \\    check("aé€👋z", "mixed widths")
        \\    # The first multi-byte scalar atevery position of a growing prefix.
        \\    var prefix = ""
        \\    var n = 0
        \\    while n < 30:
        \\        check(prefix + "é" + ascii_long, "multi at " + str(n))
        \\        check(prefix + "é", "multi at end " + str(n))
        \\        prefix = prefix + "a"
        \\        n += 1
        \\    # Either side of the inline boundary, both representations.
        \\    var grown = ""
        \\    var m = 0
        \\    while m < 30:
        \\        check(grown, "grown " + str(m))
        \\        check(grown + "é", "grown wide " + str(m))
        \\        grown = grown + "x"
        \\        m += 1
        \\    # Slices of slices, and joins of every combination.
        \\    let wide = "aé€👋zabcdefghijklmnopqrstuvwxyz"
        \\    check(wide[1:8], "slice of wide")
        \\    check(wide[1:8][1:4], "slice of slice")
        \\    check(ascii_long + ascii_long, "ascii + ascii")
        \\    check(ascii_long + wide, "ascii + wide")
        \\    check(wide + ascii_long, "wide + ascii")
        \\    check(wide + wide, "wide + wide")
        \\    print("agreed")
    ,
        \\agreed
        \\
    );
}
