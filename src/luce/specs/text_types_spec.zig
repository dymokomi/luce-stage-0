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
        \\    var points = new list[u32]
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
        \\    value: char
        \\    fallback: char?
        \\
        \\func main():
        \\    let mark = Mark(value = 'λ', fallback = none)
        \\    var values = new list[char]
        \\    values.append(mark.value)
        \\    values.append('🙂')
        \\    var grid = new array[char](2)
        \\    grid[0] = values[1]
        \\    grid[1] = mark.fallback else 'x'
        \\    print(str(values[0]) + str(grid[0]) + str(grid[1]))
        \\
    , "λ🙂x\n");
}

test "character containers sort at scalar order" {
    try agree.prints(
        \\func main():
        \\    var values = new list[char]
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
        \\    var source = new list[u8]
        \\    source.append(u8(65))
        \\    source.append(u8(66))
        \\    let copied = bytes(source)
        \\    source[0] = u8(90)
        \\    print(parse_str(copied) else "not text")
        \\
        \\    var buffer = new array[u8](3)
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
        \\    var raw = new list[u8]
        \\    raw.append(u8(0xff))
        \\    raw.append(u8(0xfe))
        \\    print(parse_str(bytes(raw)) else "not text")
        \\
    , "true\ntrue\nbc\nnot text\n");
}

test "bytes iterate as u8 and preserve empty inline and outside storage" {
    try agree.prints(
        \\struct Packet:
        \\    body: bytes
        \\    mark: char
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
        \\const mark: Rune = 'λ'
        \\func main():
        \\    let copied = Rune(u32(mark))
        \\
    );
    try expectCompiles("bytes alias and constant",
        \\alias Data = bytes
        \\const payload: Data = bytes("hello")
        \\func main():
        \\    let copied: Data = Data(payload)
        \\
    );
    try agree.prints(
        \\alias Rune = char
        \\alias Data = bytes
        \\const mark: Rune = 'λ'
        \\const payload: Data = bytes("hello")
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
    try expectRejected(
        "func main():\n    let value = i64('a')\n",
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

test "retired character helper names are ordinary user names" {
    try agree.prints(
        \\func chr(value: i64) -> i64:
        \\    return value + 1
        \\
        \\func ord(value: i64) -> i64:
        \\    return value + 2
        \\
        \\func main():
        \\    print(str(chr(40)))
        \\    print(str(ord(40)))
        \\
    , "41\n42\n");
}
