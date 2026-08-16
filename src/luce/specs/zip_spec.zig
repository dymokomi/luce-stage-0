//! `std.zip`, proven the way every std module is proven: Luce
//! programs whose asserts trap on a wrong answer, run on both engines
//! and compared (`specs/agree.zig`).
//!
//! Two things make this suite different from the rest of
//! `std_spec.zig`, and both are the point of having it apart.
//!
//! **It is a container format, so the specification is other
//! people's bytes.**  Two archives written by Info-ZIP — one stored,
//! one deflated with a dynamic Huffman block — are embedded below as
//! the decimal bytes they are, and the programs read them.  A library
//! that only reads what it wrote has proven nothing about ZIP.
//!
//! **Bytes are a `list(byte)`, one byte to an element**, because the
//! host cannot hand a program a file's bytes: `file_read` answers a
//! `string` and a string is valid UTF-8, so an archive never survives
//! the boundary.  Nothing here touches the world — `std.zip` is a
//! pure module and these programs compile without host access — and
//! that is the honest shape of the gap, not a convenience of the
//! tests.

const std = @import("std");
const agree = @import("agree.zig");

/// The depth the std suite has always run at.
const budget: agree.Provided = .{ .call_depth = 4096 };

fn agreeOk(source: []const u8) !void {
    return agree.okGiven(source, budget);
}

/// The run ends as an error nobody caught, with exactly these words.
fn agreeRaises(source: []const u8, message: []const u8) !void {
    return agree.errors(source, budget, .user_error, message);
}

// ---------------------------------------------------------------------------
// The checksum
// ---------------------------------------------------------------------------

test "zip: CRC-32 answers the published check values" {
    try agreeOk(
        \\import std.zip
        \\
        \\func main():
        \\    # The check value every CRC-32 implementation is measured
        \\    # against, and three that bracket it.
        \\    assert(zip.crc32(zip.bytes("123456789")) == 3421780262)
        \\    assert(zip.crc32(zip.bytes("")) == 0)
        \\    assert(zip.crc32(zip.bytes("a")) == 3904355907)
        \\    assert(zip.crc32(zip.bytes("hello\n")) == 909783072)
        \\
        \\    # Bytes no str could hold: three NULs, four 0xFFs, and
        \\    # every u8 there is, in order.
        \\    var nuls: list[u8] = [0, 0, 0]
        \\    assert(zip.crc32(nuls) == 4282505490)
        \\    var ones: list[u8] = [255, 255, 255, 255]
        \\    assert(zip.crc32(ones) == 4294967295)
        \\    var every: list[u8] = []
        \\    for value in range(0, 256):
        \\        every.append(u8(value))
        \\    assert(zip.crc32(every) == 688229491)
        \\
    );
}

// ---------------------------------------------------------------------------
// Bytes and text
// ---------------------------------------------------------------------------

test "zip: bytes and text are inverse over anything a string can hold" {
    try agreeOk(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    let plain = "the quick brown fox"
        \\    let plain_again = zip.text(zip.bytes(plain)) else ""
        \\    assert(plain_again == plain)
        \\    let wide = "héllo — λ"
        \\    let wide_again = zip.text(zip.bytes(wide)) else ""
        \\    assert(wide_again == wide)
        \\    let nothing = zip.text(zip.bytes("")) else ""
        \\    assert(nothing == "")
        \\
        \\    # A NUL is a character like any other: one u8, and it
        \\    # survives both ways.
        \\    var nul: list[u8] = [104, 0, 105]
        \\    let held = zip.text(nul) else ""
        \\    assert(len(held) == 3)
        \\    assert(held.byte_at(1) == 0)
        \\
        \\    # The widths, one of each.
        \\    assert(len(zip.bytes("a")) == 1)
        \\    assert(len(zip.bytes("é")) == 2)
        \\    assert(len(zip.bytes("—")) == 3)
        \\
    );
}

test "zip: bytes that are not text answer absence, and one reason covers all of them" {
    // **This test had five sentences and now it has one**
    // (docs/BYTES.md R3).  `zip.text` was a hand-written UTF-8 decoder
    // that named the byte and the kind of malformation, because it was
    // a second implementation of a validator and could afford to; it is
    // `strings.from_bytes` now, and "not UTF-8" is the same fact every
    // time, so absence carries all the information there is.  The four
    // shapes still have to be *refused* — a lead byte no sequence
    // begins with, a sequence cut short, an overlong encoding, and a
    // surrogate — and they are.
    try agreeOk(
        \\import std.zip
        \\
        \\func main():
        \\    var loose: list[u8] = [111, 107, 128]
        \\    assert(zip.text(loose) == none)
        \\    var cut: list[u8] = [99, 97, 102, 195]
        \\    assert(zip.text(cut) == none)
        \\    var overlong: list[u8] = [192, 175]
        \\    assert(zip.text(overlong) == none)
        \\    var surrogate: list[u8] = [237, 160, 128]
        \\    assert(zip.text(surrogate) == none)
        \\
    );
}

// ---------------------------------------------------------------------------
// Written here, read back here
// ---------------------------------------------------------------------------

test "zip: an archive this module wrote is one it can read" {
    try agreeOk(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    # Four entries of four shapes: nothing at all, a line of
        \\    # text, every u8 there is, and one i64 enough to have
        \\    # a structure.
        \\    var nothing: list[u8] = []
        \\    var every: list[u8] = []
        \\    for value in range(0, 256):
        \\        every.append(u8(value))
        \\    var large: list[u8] = []
        \\    for step in range(0, 5000):
        \\        large.append(u8(step % 251))
        \\
        \\    var writer = zip.writer()
        \\    try writer.add("empty", nothing)
        \\    try writer.add("greeting.txt", zip.bytes("hello, world\n"))
        \\    try writer.add("every.bin", every)
        \\    try writer.add("large.bin", large)
        \\    let archive = writer.finish()
        \\
        \\    let found = try zip.entries(archive)
        \\    assert(len(found) == 4)
        \\    assert(found[0].name() == "empty")
        \\    assert(found[0].size() == 0)
        \\    assert(found[1].name() == "greeting.txt")
        \\    assert(found[1].size() == 13)
        \\    assert(found[1].crc() == zip.crc32(zip.bytes("hello, world\n")))
        \\    assert(found[2].name() == "every.bin")
        \\    assert(found[2].size() == 256)
        \\    assert(found[3].size() == 5000)
        \\    for entry in found:
        \\        assert(not entry.deflated())
        \\
        \\    let blank = try zip.extract(archive, found[0])
        \\    assert(len(blank) == 0)
        \\    let greeting = try zip.extract(archive, found[1])
        \\    let said = zip.text(greeting) else ""
        \\    assert(said == "hello, world\n")
        \\    let back = try zip.extract(archive, found[2])
        \\    assert(len(back) == 256)
        \\    for index in range(0, 256):
        \\        assert(back[index] == index)
        \\    let bulk = try zip.extract(archive, found[3])
        \\    assert(len(bulk) == 5000)
        \\    for index in range(0, 5000):
        \\        assert(bulk[index] == index % 251)
        \\
    );
}

test "zip: compressing an entry changes its size and nothing else" {
    try agreeOk(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    var text = ""
        \\    for step in range(0, 60):
        \\        text += "luce compiles bytes into machine code. "
        \\    let data = zip.bytes(text)
        \\
        \\    var writer = zip.writer()
        \\    try writer.add("prose.txt", data, compress = true)
        \\    # Nothing to gain: a compressed entry never grows, so this
        \\    # one is stored whole instead.
        \\    var one: list[u8] = [7]
        \\    try writer.add("one.bin", one, compress = true)
        \\    let archive = writer.finish()
        \\
        \\    let found = try zip.entries(archive)
        \\    assert(found[0].deflated())
        \\    assert(found[0].packed() < found[0].size())
        \\    assert(found[0].size() == len(data))
        \\    assert(not found[1].deflated())
        \\    assert(found[1].packed() == 1)
        \\
        \\    let prose = try zip.extract(archive, found[0])
        \\    let said = zip.text(prose) else ""
        \\    assert(said == text)
        \\    let one_back = try zip.extract(archive, found[1])
        \\    assert(len(one_back) == 1)
        \\    assert(one_back[0] == 7)
        \\
    );
}

test "zip: deflate and inflate are inverse, on text and on raw bytes" {
    try agreeOk(
        \\import std.zip
        \\
        \\func same(left: list[u8], right: list[u8]) -> bool:
        \\    if len(left) != len(right):
        \\        return false
        \\    for index in range(0, len(left)):
        \\        if left[index] != right[index]:
        \\            return false
        \\    return true
        \\
        \\func main() -> !:
        \\    # Nothing at all: an empty stream is still a block.
        \\    var nothing: list[u8] = []
        \\    let nothing_back = try zip.inflate(zip.deflate(nothing))
        \\    assert(same(nothing_back, nothing))
        \\
        \\    # Every u8, which compresses to nothing worth having.
        \\    var every: list[u8] = []
        \\    for value in range(0, 256):
        \\        every.append(u8(value))
        \\    let every_back = try zip.inflate(zip.deflate(every))
        \\    assert(same(every_back, every))
        \\
        \\    # Prose, which the matcher does have something to say about.
        \\    var text = ""
        \\    for step in range(0, 80):
        \\        text += "the quick brown fox jumps over the lazy dog. "
        \\    let prose = zip.bytes(text)
        \\    let squeezed = zip.deflate(prose)
        \\    assert(len(squeezed) < len(prose) // 8)
        \\    let prose_back = try zip.inflate(squeezed)
        \\    assert(same(prose_back, prose))
        \\
        \\    # One u8 repeated far enough to need a i64 match copying
        \\    # out of what it is still writing.
        \\    var run: list[u8] = []
        \\    for step in range(0, 3000):
        \\        run.append(65)
        \\    let run_back = try zip.inflate(zip.deflate(run))
        \\    assert(same(run_back, run))
        \\
    );
}

// ---------------------------------------------------------------------------
// Other people's bytes
// ---------------------------------------------------------------------------

test "zip: what Info-ZIP stored, std.zip reads" {
    try agreeOk(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    let archive = stored()
        \\    assert(len(archive) == 220)
        \\    let found = try zip.entries(archive)
        \\    assert(len(found) == 2)
        \\
        \\    assert(found[0].name() == "a.txt")
        \\    assert(found[0].size() == 6)
        \\    assert(not found[0].deflated())
        \\    assert(found[0].crc() == 909783072)
        \\    let first = try zip.extract(archive, found[0])
        \\    let first_text = zip.text(first) else ""
        \\    assert(first_text == "hello\n")
        \\
        \\    assert(found[1].name() == "b.txt")
        \\    assert(found[1].size() == 20)
        \\    assert(found[1].crc() == 1272601271)
        \\    let second = try zip.extract(archive, found[1])
        \\    let second_text = zip.text(second) else ""
        \\    assert(second_text == "world contents here\n")
        \\
    ++ fixtures);
}

test "zip: an archive Info-ZIP wrote survives a real file, both ways" {
    // **The end of docs/BYTES.md, as one program.**  The archive is
    // Info-ZIP's own bytes; it goes out through `zip.write` — which is
    // `files.write_bytes`, which is a loop over a handle whose host
    // takes three bytes at a time on purpose — comes back through
    // `zip.read`, and is then read as an archive.  Nothing about it is
    // text: byte 0 of the local header is `P`, but byte 8 is a zero and
    // there is a 0xF9 further in, so this is the file the boundary used
    // to refuse in both directions.
    //
    // A host is needed now, where every other test on this page runs
    // without one — which is itself the measurement: `std.zip` was a
    // pure module because it had to be.
    var provided = budget;
    provided.world = .{};
    try agree.okGiven(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    let original = stored()
        \\    try zip.write("out.zip", original)
        \\
        \\    let back = try zip.read("out.zip")
        \\    assert(len(back) == len(original))
        \\    var at = 0
        \\    while at < len(back):
        \\        assert(back[at] == original[at])
        \\        at += 1
        \\
        \\    # And it is still an archive after the round trip, which
        \\    # is the claim a u8 comparison alone does not make.
        \\    let found = try zip.entries(back)
        \\    assert(len(found) == 2)
        \\    assert(found[0].name() == "a.txt")
        \\    let first = try zip.extract(back, found[0])
        \\    assert((zip.text(first) else "") == "hello\n")
        \\
    ++ fixtures, provided);
}

test "zip: an archive std.zip wrote to a file is one it reads back" {
    // The other direction: built here, written, read, and checked
    // against what went in.  `writer.finish` answers bytes and
    // `zip.write` puts them somewhere — the seam this module always
    // had and could never reach.
    var provided = budget;
    provided.world = .{};
    try agree.okGiven(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    var writer = zip.writer()
        \\    try writer.add("greeting.txt", zip.bytes("hello, world\n"))
        \\    var raw: list[u8] = [0, 255, 128, 1]
        \\    try writer.add("every.bin", raw)
        \\    try zip.write("built.zip", writer.finish())
        \\
        \\    let found = try zip.entries(try zip.read("built.zip"))
        \\    assert(len(found) == 2)
        \\    assert(found[0].name() == "greeting.txt")
        \\    assert(found[1].name() == "every.bin")
        \\
        \\    let archive = try zip.read("built.zip")
        \\    let said = try zip.extract(archive, found[0])
        \\    assert((zip.text(said) else "") == "hello, world\n")
        \\    # The entry no str could ever have held.
        \\    let every = try zip.extract(archive, found[1])
        \\    assert(len(every) == 4)
        \\    assert(i32(every[1]) == 255)
        \\    assert(zip.text(every) == none)
        \\
    , provided);
}

test "zip: what Info-ZIP deflated, std.zip inflates" {
    try agreeOk(
        \\import std.zip
        \\import std.strings
        \\
        \\func main() -> !:
        \\    # A dynamic Huffman block, written by Info-ZIP at -9: the
        \\    # tables come out of the stream, not out of RFC 1951.
        \\    let archive = dynamic()
        \\    let found = try zip.entries(archive)
        \\    assert(len(found) == 1)
        \\    assert(found[0].name() == "note.txt")
        \\    assert(found[0].deflated())
        \\    assert(found[0].size() == 3633)
        \\    assert(found[0].packed() < 1000)
        \\    assert(found[0].crc() == 4136620764)
        \\
        \\    # extract checks the CRC itself, so arriving here is most
        \\    # of the proof; the rest is that the bytes are the words.
        \\    let data = try zip.extract(archive, found[0])
        \\    let note = zip.text(data) else ""
        \\    assert(len(note) == 3633)
        \\    assert(note.starts_with("entry trap huffman trap error ownership entry entry huffman"))
        \\    assert(note.ends_with("machine archive zip entry entry deflate compile error error\n"))
        \\
    ++ fixtures);
}

test "zip: an archive rebuilt out of one Info-ZIP wrote holds the same bytes" {
    // The two directions meet: what this module writes goes back
    // through the same reader that reads Info-ZIP's bytes.
    try agreeOk(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    let original = stored()
        \\    let found = try zip.entries(original)
        \\    var writer = zip.writer()
        \\    for entry in found:
        \\        let data = try zip.extract(original, entry)
        \\        try writer.add(entry.name(), data, compress = true)
        \\    let rebuilt = writer.finish()
        \\
        \\    let again = try zip.entries(rebuilt)
        \\    assert(len(again) == 2)
        \\    for index in range(0, 2):
        \\        assert(again[index].name() == found[index].name())
        \\        assert(again[index].size() == found[index].size())
        \\        assert(again[index].crc() == found[index].crc())
        \\        let was = try zip.extract(original, found[index])
        \\        let now = try zip.extract(rebuilt, again[index])
        \\        assert(len(was) == len(now))
        \\        for at in range(0, len(was)):
        \\            assert(was[at] == now[at])
        \\
    ++ fixtures);
}

// ---------------------------------------------------------------------------
// Damaged archives
// ---------------------------------------------------------------------------

test "zip: bytes that are not an archive answer by name" {
    try agreeRaises(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    var scraps: list[u8] = [80, 75, 3]
        \\    let found = try zip.entries(scraps)
        \\
    , "zip: not an archive (only 3 bytes)");

    try agreeRaises(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    let prose = zip.bytes("this file is prose, not an archive at all")
        \\    let found = try zip.entries(prose)
        \\
    , "zip: not an archive (no end-of-central-directory record)");
}

test "zip: an archive cut short says it is truncated" {
    try agreeRaises(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    let whole = stored()
        \\    # Keep the end record and lose the directory it points at.
        \\    var cut: list[u8] = []
        \\    for index in range(0, len(whole)):
        \\        if index < 60 or index >= len(whole) - 22:
        \\            cut.append(whole[index])
        \\    let found = try zip.entries(cut)
        \\
    ++ fixtures, "zip: the archive is truncated");
}

test "zip: a directory entry with no header on it says which one" {
    try agreeRaises(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    var damaged = copied()
        \\    # The central directory starts at 96; break its signature.
        \\    damaged[96] = 88
        \\    let found = try zip.entries(damaged)
        \\
    ++ fixtures, "zip: entry 1 of the central directory has no header");
}

test "zip: contents that do not match their checksum are refused" {
    try agreeRaises(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    var damaged = copied()
        \\    # "hello\n" begins at 35; make it "jello\n".
        \\    damaged[35] = 106
        \\    let found = try zip.entries(damaged)
        \\    let data = try zip.extract(damaged, found[0])
        \\
    ++ fixtures, "zip: a.txt fails its checksum");
}

test "zip: a compression method this module does not have is named" {
    try agreeRaises(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    var damaged = copied()
        \\    # Method 14 is LZMA, in the directory's copy of the field.
        \\    damaged[106] = 14
        \\    let found = try zip.entries(damaged)
        \\    let data = try zip.extract(damaged, found[0])
        \\
    ++ fixtures, "zip: a.txt uses compression method 14, which zip cannot read");
}

test "zip: an entry an archive says is encrypted is not half-read" {
    try agreeRaises(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    var damaged = copied()
        \\    # Flag bit 0, in the directory's copy of the flags.
        \\    damaged[104] = 1
        \\    let found = try zip.entries(damaged)
        \\
    ++ fixtures, "zip: entry 1 is encrypted");
}

test "zip: a compressed stream that is not one says so" {
    try agreeRaises(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    # Block kind 3 is the one DEFLATE reserves and never uses.
        \\    var nonsense: list[u8] = [7, 0, 0, 0]
        \\    let back = try zip.inflate(nonsense)
        \\
    , "zip: the compressed stream has a block of an unknown kind");

    try agreeRaises(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    # A final stored block whose length and complement disagree.
        \\    var wrong: list[u8] = [1, 4, 0, 0, 0, 65, 66, 67, 68]
        \\    let back = try zip.inflate(wrong)
        \\
    , "zip: a stored block whose length does not check out");

    try agreeRaises(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    # A fixed-Huffman block that ends before its codes do.
        \\    var fragment: list[u8] = [3]
        \\    let back = try zip.inflate(fragment)
        \\
    , "zip: the compressed stream ends in the middle of a code");
}

test "zip: an entry needs a name" {
    try agreeRaises(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    var writer = zip.writer()
        \\    var nothing: list[u8] = []
        \\    try writer.add("", nothing)
        \\
    , "zip: an entry needs a name");
}

test "zip: a fixed Huffman block, which is the one RFC 1951 prints" {
    try agreeOk(
        \\import std.zip
        \\import std.strings
        \\
        \\func main() -> !:
        \\    # Short and repetitive, so Info-ZIP had nothing to gain by
        \\    # carrying its own tables and reached for §3.2.6's.
        \\    let archive = fixed()
        \\    let found = try zip.entries(archive)
        \\    assert(len(found) == 1)
        \\    assert(found[0].name() == "song.txt")
        \\    assert(found[0].deflated())
        \\    assert(found[0].size() == 126)
        \\    assert(found[0].crc() == 1425122749)
        \\    let data = try zip.extract(archive, found[0])
        \\    let song = zip.text(data) else ""
        \\    assert(song == "la la la la la la la la la la la la la la\n".repeat(3))
        \\
    ++ fixtures);
}

test "zip: an entry written without seeking reads from the directory" {
    // APPNOTE 4.4.4 bit 3: a writer that cannot seek leaves the local
    // header's CRC and sizes zero and puts the real ones behind the
    // data.  4.4.7 and 4.4.8 require the central directory to carry
    // them too, so a reader that believes the directory needs to know
    // nothing about data descriptors — and this is the fixture that
    // proves this one does.  Written by Python's zipfile into a
    // non-seekable sink.
    try agreeOk(
        \\import std.zip
        \\import std.strings
        \\
        \\func main() -> !:
        \\    let archive = descriptor()
        \\    let found = try zip.entries(archive)
        \\    assert(len(found) == 1)
        \\    assert(found[0].name() == "streamed.txt")
        \\    assert(found[0].deflated())
        \\    assert(found[0].size() == 160)
        \\    assert(found[0].crc() == 4101820766)
        \\    let data = try zip.extract(archive, found[0])
        \\    let text = zip.text(data) else ""
        \\    assert(len(text) == 160)
        \\    assert(text.starts_with("a line that was written without seeking\n"))
        \\
    ++ fixtures);
}

test "zip: an archive with a program in front of it still reads" {
    // APPNOTE 4.4.16: offsets are measured from the start of the
    // archive, and a self-extracting file starts with something else.
    // The directory ends where the end record begins, so how far it
    // really starts from what it claims is how far everything moved.
    try agreeOk(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    let archive = prefixed()
        \\    let plain = stored()
        \\    assert(len(archive) == len(plain) + 52)
        \\    let found = try zip.entries(archive)
        \\    assert(len(found) == 2)
        \\    assert(found[0].name() == "a.txt")
        \\    let first = try zip.extract(archive, found[0])
        \\    let said = zip.text(first) else ""
        \\    assert(said == "hello\n")
        \\    assert(found[1].name() == "b.txt")
        \\    let second = try zip.extract(archive, found[1])
        \\    let also = zip.text(second) else ""
        \\    assert(also == "world contents here\n")
        \\
    ++ fixtures);
}

test "zip: a signature inside a comment is not the end record" {
    // The .ZIP file comment is arbitrary bytes and may hold the end
    // record's own signature.  A match is the record only when its
    // comment length reaches exactly the end of the archive, which is
    // what tells the outer archive from a whole one pasted into a
    // comment.
    try agreeOk(
        \\import std.zip
        \\
        \\func main() -> !:
        \\    let inner = stored()
        \\    var archive: list[u8] = []
        \\    for index in range(0, len(inner)):
        \\        archive.append(inner[index])
        \\    # Say the comment is the whole of another archive, and put
        \\    # one there: the bytes now hold two end-record signatures.
        \\    archive[len(archive) - 2] = u8(len(inner) & 0xFF)
        \\    archive[len(archive) - 1] = u8(len(inner) >> 8 & 0xFF)
        \\    for index in range(0, len(inner)):
        \\        archive.append(inner[index])
        \\    let found = try zip.entries(archive)
        \\    assert(len(found) == 2)
        \\    assert(found[0].name() == "a.txt")
        \\
    ++ fixtures);
}

/// The archives the programs above read, as the bytes they are.  Four
/// came out of real tools and one is a shape rather than a tool's
/// output; each is here because it is a clause of the format that
/// reading only what this module wrote would never reach:
///
///  * `stored()` — Info-ZIP `zip -X -0`, two short text files, method 0.
///  * `dynamic()` — Info-ZIP `zip -X -9`, a file varied enough that the
///    compressor carried its own Huffman tables (RFC 1951 §3.2.7).
///  * `fixed()` — Info-ZIP `zip -X -9` over something short and
///    repetitive, which is answered with §3.2.6's fixed tables instead.
///  * `descriptor()` — Python's `zipfile` writing to a non-seekable
///    sink, so general purpose bit 3 is set and the local header's CRC
///    and sizes are zeros (APPNOTE 4.4.4).
///  * `prefixed()` — `stored()` with 52 bytes of shell script in front
///    of it, the shape a self-extracting archive has.
///
/// `copied()` hands back a writable copy of `stored()` for the damage
/// tests.  Appended to whichever program wants them, because a std
/// spec's program is one file.
const fixtures =
    \\
    \\func copied() -> list[u8]:
    \\    let whole = stored()
    \\    var loose: list[u8] = []
    \\    for index in range(0, len(whole)):
    \\        loose.append(whole[index])
    \\    return loose
    \\
    \\
    \\func stored() -> list[u8]:
    \\    var data: list[u8] = [80, 75, 3, 4, 10, 0, 0, 0, 0, 0, 249, 139, 6, 93, 32, 48, 58, 54, 6, 0, 0, 0, 6, 0, 0, 0, 5, 0, 0, 0, 97, 46, 116, 120, 116, 104, 101, 108, 108, 111, 10, 80, 75, 3, 4, 10, 0, 0, 0, 0, 0, 249, 139, 6, 93, 183, 90, 218, 75, 20, 0, 0, 0, 20, 0, 0, 0, 5, 0, 0, 0, 98, 46, 116, 120, 116, 119, 111, 114, 108, 100, 32, 99, 111, 110, 116, 101, 110, 116, 115, 32, 104, 101, 114, 101, 10, 80, 75, 1, 2, 30, 3, 10, 0, 0, 0, 0, 0, 249, 139, 6, 93, 32, 48, 58, 54, 6, 0, 0, 0, 6, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 164, 129, 0, 0, 0, 0, 97, 46, 116, 120, 116, 80, 75, 1, 2, 30, 3, 10, 0, 0, 0, 0, 0, 249, 139, 6, 93, 183, 90, 218, 75, 20, 0, 0, 0, 20, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 164, 129, 41, 0, 0, 0, 98, 46, 116, 120, 116, 80, 75, 5, 6, 0, 0, 0, 0, 2, 0, 2, 0, 102, 0, 0, 0, 96, 0, 0, 0, 0, 0]
    \\    return data
    \\
    \\func dynamic() -> list[u8]:
    \\    var data: list[u8] = [80, 75, 3, 4, 20, 0, 2, 0, 8, 0, 249, 139, 6, 93, 220, 210, 143, 246, 236, 2, 0, 0, 49, 14, 0, 0, 8, 0, 0, 0, 110, 111, 116, 101, 46, 116, 120, 116, 125, 87, 91, 146, 218, 64, 12, 252, 215, 41, 124, 53, 135, 152, 90, 170, 120, 108, 25, 54, 169, 245, 233, 131, 71, 234, 81, 183, 198, 155, 31, 96, 108, 73, 211, 122, 181, 196, 114, 127, 173, 223, 211, 107, 157, 63, 167, 143, 175, 243, 249, 54, 223, 253, 176, 172, 235, 99, 157, 30, 127, 239, 203, 250, 252, 184, 188, 207, 77, 206, 63, 67, 208, 154, 224, 243, 181, 46, 243, 109, 250, 189, 156, 175, 243, 107, 153, 182, 183, 108, 106, 193, 164, 235, 157, 30, 183, 207, 203, 117, 9, 21, 75, 177, 93, 233, 250, 120, 220, 66, 238, 114, 79, 91, 237, 49, 204, 116, 13, 115, 120, 183, 249, 244, 113, 185, 47, 221, 240, 245, 235, 4, 235, 211, 188, 190, 223, 253, 89, 202, 213, 161, 97, 33, 132, 199, 251, 77, 241, 168, 217, 144, 120, 52, 8, 251, 99, 107, 239, 224, 169, 67, 192, 137, 181, 107, 212, 126, 125, 191, 150, 167, 249, 239, 144, 107, 23, 64, 23, 23, 225, 12, 84, 136, 67, 211, 244, 203, 187, 167, 25, 173, 42, 13, 199, 123, 236, 119, 156, 158, 171, 166, 133, 160, 65, 190, 161, 35, 204, 21, 85, 200, 249, 253, 205, 66, 248, 144, 42, 237, 41, 238, 109, 135, 118, 29, 52, 229, 77, 198, 87, 178, 134, 91, 37, 186, 145, 230, 38, 224, 206, 194, 20, 156, 192, 89, 174, 136, 250, 130, 125, 152, 76, 188, 53, 100, 30, 130, 166, 43, 143, 220, 103, 216, 166, 180, 58, 172, 93, 126, 163, 136, 1, 212, 254, 34, 194, 149, 200, 107, 81, 108, 132, 163, 20, 128, 73, 155, 13, 230, 181, 111, 128, 14, 182, 226, 108, 146, 19, 124, 195, 84, 195, 5, 87, 91, 50, 210, 104, 68, 175, 23, 95, 166, 128, 123, 28, 22, 153, 3, 2, 2, 154, 43, 211, 205, 65, 210, 22, 215, 126, 129, 166, 231, 131, 107, 72, 19, 156, 31, 136, 88, 233, 103, 241, 83, 140, 250, 103, 60, 242, 198, 162, 230, 95, 146, 13, 227, 201, 254, 178, 157, 1, 224, 253, 192, 152, 54, 52, 78, 184, 248, 136, 26, 193, 61, 28, 198, 202, 96, 63, 81, 65, 103, 51, 111, 11, 166, 18, 109, 190, 222, 164, 25, 125, 208, 53, 144, 214, 122, 170, 189, 84, 67, 158, 243, 192, 36, 76, 144, 3, 230, 173, 119, 6, 55, 66, 11, 152, 38, 31, 10, 112, 142, 131, 197, 78, 129, 63, 148, 113, 53, 208, 253, 170, 238, 120, 129, 31, 193, 146, 138, 232, 69, 169, 4, 0, 92, 209, 1, 125, 252, 248, 219, 116, 143, 88, 125, 24, 44, 192, 163, 182, 134, 1, 83, 137, 45, 152, 206, 109, 86, 134, 78, 204, 165, 204, 27, 209, 56, 154, 255, 80, 123, 247, 35, 135, 134, 1, 158, 94, 72, 208, 52, 145, 229, 219, 116, 202, 51, 118, 162, 82, 160, 140, 213, 161, 21, 80, 14, 7, 105, 42, 26, 37, 125, 60, 112, 145, 219, 145, 247, 149, 220, 56, 190, 84, 70, 150, 190, 203, 244, 212, 198, 173, 131, 197, 249, 95, 218, 110, 136, 134, 116, 3, 127, 238, 248, 77, 214, 135, 97, 131, 201, 237, 130, 169, 152, 97, 71, 94, 153, 120, 165, 175, 234, 88, 41, 36, 204, 165, 122, 192, 229, 158, 39, 222, 180, 10, 123, 215, 53, 224, 231, 148, 247, 60, 19, 55, 81, 206, 187, 37, 151, 174, 243, 170, 176, 146, 213, 236, 230, 157, 71, 191, 244, 6, 57, 89, 29, 122, 72, 23, 65, 103, 42, 222, 48, 154, 141, 198, 143, 11, 251, 242, 180, 135, 77, 50, 192, 3, 212, 202, 14, 123, 20, 120, 25, 14, 160, 167, 26, 143, 227, 149, 89, 251, 180, 55, 144, 18, 50, 245, 94, 34, 150, 41, 207, 221, 84, 152, 171, 214, 160, 22, 8, 132, 135, 81, 45, 166, 120, 49, 56, 160, 221, 84, 150, 209, 62, 238, 103, 90, 107, 195, 226, 203, 148, 87, 195, 134, 243, 0, 152, 162, 51, 108, 134, 146, 152, 241, 63, 8, 211, 163, 213, 61, 14, 23, 11, 135, 242, 194, 3, 75, 233, 189, 78, 155, 58, 49, 202, 228, 56, 220, 246, 172, 236, 108, 176, 161, 117, 38, 155, 1, 209, 186, 213, 137, 191, 149, 63, 120, 117, 251, 96, 221, 127, 80, 75, 1, 2, 30, 3, 20, 0, 2, 0, 8, 0, 249, 139, 6, 93, 220, 210, 143, 246, 236, 2, 0, 0, 49, 14, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 164, 129, 0, 0, 0, 0, 110, 111, 116, 101, 46, 116, 120, 116, 80, 75, 5, 6, 0, 0, 0, 0, 1, 0, 1, 0, 54, 0, 0, 0, 18, 3, 0, 0, 0, 0]
    \\    return data
    \\
    \\func fixed() -> list[u8]:
    \\    var data: list[u8] = [80, 75, 3, 4, 20, 0, 2, 0, 8, 0, 249, 139, 6, 93, 189, 165, 241, 84, 12, 0, 0, 0, 126, 0, 0, 0, 8, 0, 0, 0, 115, 111, 110, 103, 46, 116, 120, 116, 203, 73, 84, 200, 33, 10, 113, 229, 208, 64, 37, 0, 80, 75, 1, 2, 30, 3, 20, 0, 2, 0, 8, 0, 249, 139, 6, 93, 189, 165, 241, 84, 12, 0, 0, 0, 126, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 164, 129, 0, 0, 0, 0, 115, 111, 110, 103, 46, 116, 120, 116, 80, 75, 5, 6, 0, 0, 0, 0, 1, 0, 1, 0, 54, 0, 0, 0, 50, 0, 0, 0, 0, 0]
    \\    return data
    \\
    \\func descriptor() -> list[u8]:
    \\    var data: list[u8] = [80, 75, 3, 4, 20, 0, 8, 0, 8, 0, 0, 0, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12, 0, 0, 0, 115, 116, 114, 101, 97, 109, 101, 100, 46, 116, 120, 116, 75, 84, 200, 201, 204, 75, 85, 40, 201, 72, 44, 81, 40, 79, 44, 86, 40, 47, 202, 44, 41, 73, 205, 83, 40, 207, 44, 201, 200, 47, 45, 81, 40, 78, 77, 205, 206, 204, 75, 231, 74, 28, 32, 117, 0, 80, 75, 7, 8, 94, 209, 124, 244, 45, 0, 0, 0, 160, 0, 0, 0, 80, 75, 1, 2, 20, 3, 20, 0, 8, 0, 8, 0, 0, 0, 33, 0, 94, 209, 124, 244, 45, 0, 0, 0, 160, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 1, 0, 0, 0, 0, 115, 116, 114, 101, 97, 109, 101, 100, 46, 116, 120, 116, 80, 75, 5, 6, 0, 0, 0, 0, 1, 0, 1, 0, 58, 0, 0, 0, 103, 0, 0, 0, 0, 0]
    \\    return data
    \\
    \\func prefixed() -> list[u8]:
    \\    var data: list[u8] = [35, 33, 47, 98, 105, 110, 47, 115, 104, 10, 35, 32, 97, 32, 112, 114, 111, 103, 114, 97, 109, 32, 105, 110, 32, 102, 114, 111, 110, 116, 32, 111, 102, 32, 97, 110, 32, 97, 114, 99, 104, 105, 118, 101, 10, 101, 120, 105, 116, 32, 48, 10, 80, 75, 3, 4, 10, 0, 0, 0, 0, 0, 249, 139, 6, 93, 32, 48, 58, 54, 6, 0, 0, 0, 6, 0, 0, 0, 5, 0, 0, 0, 97, 46, 116, 120, 116, 104, 101, 108, 108, 111, 10, 80, 75, 3, 4, 10, 0, 0, 0, 0, 0, 249, 139, 6, 93, 183, 90, 218, 75, 20, 0, 0, 0, 20, 0, 0, 0, 5, 0, 0, 0, 98, 46, 116, 120, 116, 119, 111, 114, 108, 100, 32, 99, 111, 110, 116, 101, 110, 116, 115, 32, 104, 101, 114, 101, 10, 80, 75, 1, 2, 30, 3, 10, 0, 0, 0, 0, 0, 249, 139, 6, 93, 32, 48, 58, 54, 6, 0, 0, 0, 6, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 164, 129, 0, 0, 0, 0, 97, 46, 116, 120, 116, 80, 75, 1, 2, 30, 3, 10, 0, 0, 0, 0, 0, 249, 139, 6, 93, 183, 90, 218, 75, 20, 0, 0, 0, 20, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 164, 129, 41, 0, 0, 0, 98, 46, 116, 120, 116, 80, 75, 5, 6, 0, 0, 0, 0, 2, 0, 2, 0, 102, 0, 0, 0, 96, 0, 0, 0, 0, 0]
    \\    return data
;
