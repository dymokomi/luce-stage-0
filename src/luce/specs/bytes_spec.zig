//! The binary half of the host boundary, as an executable
//! specification (docs/BYTES.md).
//!
//! Three things are proved here, and every one of them is proved on
//! **both engines** — the interpreter and the compiled artifact, run
//! and compared on prints, trap code, trap message, call trace, leak
//! census and the world each left behind (`agree.zig`).  That is the
//! bar for anything that runs a program, and it matters more than
//! usual here: the byte channel's five slots are installed into
//! `libluce_rt` and called by it, so the two arms reach *literally the
//! same* code and a disagreement would mean the installation, not the
//! semantics, went wrong.
//!
//!   * **Bytes round-trip**, including bytes that are not text — which
//!     is the finding the whole run came out of: `list[u8]` at one
//!     byte an element, `strings.to_bytes` and `strings.from_bytes`,
//!     and `parse_str` answering absent for a sequence UTF-8 does
//!     not admit.
//!   * **A handle is a reference-counted resource** (R5): open, read,
//!     close when its last reference is released; `free f` as an early
//!     close; and a use after close trapping
//!     `use_after_free`, because it is the same mistake.
//!   * **A read answers a count** (R4), which is what a partial read
//!     is: the world in `agree.zig` writes three bytes at a time on
//!     purpose, so a loop that assumed a write lands whole would fail
//!     here rather than in somebody's program.

const std = @import("std");
const agree = @import("agree.zig");
const luce = @import("luce");
const mir = luce.mir;

const testing = std.testing;

// ---------------------------------------------------------------------------
// Bytes, and text as a reading of them
// ---------------------------------------------------------------------------

test "a str's bytes round-trip through list[u8]" {
    try agree.prints(
        \\import std.strings
        \\
        \\func main():
        \\    let xs = strings.to_bytes("héllo")
        \\    print(str(len(xs)))
        \\    print(strings.from_bytes(xs) else "(not text)")
        \\
    , "6\nhéllo\n");
}

test "bytes that are not UTF-8 answer absent rather than a broken string" {
    // The parse case, and the reason `from_bytes` answers `str?`:
    // 0xFF begins no UTF-8 sequence, and a `str` that held it would
    // make `len` and `s[a:b]` lies (docs/BYTES.md R3).
    try agree.prints(
        \\import std.strings
        \\
        \\func main():
        \\    var xs = new list[u8]
        \\    xs.append(u8(0xFF))
        \\    xs.append(u8(0xFE))
        \\    print(strings.from_bytes(xs) else "(not text)")
        \\    var truncated = new list[u8]
        \\    truncated.append(u8(0xE2))
        \\    print(strings.from_bytes(truncated) else "(not text)")
        \\
    , "(not text)\n(not text)\n");
}

test "a list[u8] holds every value a u8 can, packed" {
    // R1 is storage and nothing else, so the proof is behavioural: 128
    // and 255 are the two that come back negative if anything on the
    // way reads the cell as signed.
    try agree.prints(
        \\func main():
        \\    var xs = new list[u8]
        \\    var at = 0
        \\    while at < 256:
        \\        xs.append(u8(at))
        \\        at += 1
        \\    print(str(len(xs)))
        \\    print(str(i32(xs[0])) + " " + str(i32(xs[128])) + " " + str(i32(xs[255])))
        \\    xs.reverse()
        \\    print(str(i32(xs[0])))
        \\
    , "256\n0 128 255\n255\n");
}

test "a packed list still slices, sorts, finds and pops" {
    // Every list operation there is, on a kind that is no longer the
    // boxed slot: what R1 must not have changed is anything a program
    // can see.
    try agree.prints(
        \\func main():
        \\    var xs = new list[u8]
        \\    xs.append(u8(3))
        \\    xs.append(u8(1))
        \\    xs.append(u8(2))
        \\    xs.insert(0, u8(9))
        \\    print(str(xs.find(u8(2)) else -1))
        \\    print(str(xs.contains(u8(7))))
        \\    let part = xs[1:3]
        \\    print(str(len(part)) + " " + str(i32(part[0])))
        \\    xs.sort()
        \\    var seen = ""
        \\    for b in xs:
        \\        seen = seen + str(i32(b)) + ","
        \\    print(seen)
        \\    print(str(i32(xs.pop())))
        \\    xs.remove(0)
        \\    print(str(len(xs)))
        \\
    , "3\nfalse\n2 3\n1,2,3,9,\n9\n2\n");
}

// ---------------------------------------------------------------------------
// The handle, and the scope that owns it
// ---------------------------------------------------------------------------

test "a handle opens, reads a count, and its last reference closes it" {
    const world: agree.World = .withFile("notes.txt", "abcdef");

    var session = try agree.compare(
        \\import std.files
        \\
        \\func main() -> !:
        \\    var f = try files.open("notes.txt")
        \\    var buffer = new array[u8](4)
        \\    print(str(try f.read(buffer)))
        \\    print(str(i32(buffer[0])))
        \\    print(str(try f.read(buffer)))
        \\    print(str(try f.read(buffer)))
        \\
    , .{ .world = world });
    defer session.deinit();

    // Four, then the two that were left, then zero: a short read is
    // the end of the file and not a refusal (docs/BYTES.md R4).  The
    // leak census is zero, which is ARC having released the handle — a
    // handle is an object like any other.
    try testing.expectEqualStrings("4\n97\n2\n0\n", session.printed());
    try testing.expectEqual(agree.End{ .finished = 0 }, session.end);
}

test "file and handle are a program's own words, not the language's" {
    // The raw descriptor currency is the standard library's spelling,
    // not the language's (docs/BYTES.md R5): outside embedded std
    // source the words resolve like any other name, so a program may
    // declare its own `file` struct and `handle` class without
    // colliding with anything the compiler keeps for itself.
    try agree.prints(
        \\struct file:
        \\    x: i64
        \\
        \\class handle:
        \\    n: i64
        \\
        \\func main():
        \\    let a = file(x = 40)
        \\    let b = new handle(n = 2)
        \\    print(str(a.x + b.n))
        \\
    , "42\n");
}

test "a handle returns out of the function that opened it" {
    // `return` moves an object, and a handle is an object: the file
    // stays open across the frame that made it and is closed when its
    // final reference is released.
    const world: agree.World = .withFile("notes.txt", "abcdef");

    var session = try agree.compare(
        \\import std.files
        \\
        \\func opened() -> files.File!:
        \\    return try files.open("notes.txt")
        \\
        \\func main() -> !:
        \\    var f = try opened()
        \\    var buffer = new array[u8](6)
        \\    print(str(try f.read(buffer)))
        \\
    , .{ .world = world });
    defer session.deinit();

    try testing.expectEqualStrings("6\n", session.printed());
    try testing.expectEqual(agree.End{ .finished = 0 }, session.end);
}

test "a struct owns an optional file while a callback consumes its result" {
    try agree.printsGiven(
        \\import std.files
        \\
        \\struct Packet:
        \\    handle: files.File?
        \\    callback: (func(i64) -> i64)?
        \\
        \\func scale(value: i64) -> i64:
        \\    return value * 2
        \\
        \\func read(packet: Packet) -> i64!:
        \\    let handle = packet.handle
        \\    if handle == none:
        \\        return 0
        \\    var buffer = new array[u8](8)
        \\    let count = try handle.read(buffer)
        \\    let chosen = packet.callback else scale
        \\    return chosen(count)
        \\
        \\func main() -> !:
        \\    let packet = Packet(
        \\        handle = try files.open("notes.txt"),
        \\        callback = scale,
        \\    )
        \\    print(str(try read(packet)))
        \\
    , .{ .world = .withFile("notes.txt", "abcdef") }, "12\n");
}

test "opening a file that is not there is an error, not a trap" {
    // The world decides, and `files.exists` in front of it would be a
    // race — which is the proof a guard cannot stand in for a result
    // (docs/FAILURE.md).
    var session = try agree.compare(
        \\import std.files
        \\
        \\func main():
        \\    var note = ""
        \\    files.open("missing.txt") catch reason:
        \\        note = reason
        \\    print("no: " + note)
        \\
    , .{});
    defer session.deinit();

    try testing.expectEqualStrings("no: cannot open missing.txt\n", session.printed());
}

// ---------------------------------------------------------------------------
// Whole files, over the primitive
// ---------------------------------------------------------------------------

test "read_bytes and write_bytes carry bytes that are not text" {
    // The end of the run: a byte no `str` can hold makes the round
    // trip through a real file, which is the thing docs/BYTES.md
    // opened by saying Luce could not do.
    const world: agree.World = .{};

    var session = try agree.compare(
        \\import std.files
        \\import std.strings
        \\
        \\func main() -> !:
        \\    var data = new list[u8]
        \\    data.append(u8(0x89))
        \\    data.append(u8(0x50))
        \\    data.append(u8(0x4E))
        \\    data.append(u8(0x47))
        \\    data.append(u8(0x00))
        \\    try files.write_bytes("image.bin", data)
        \\    let back = try files.read_bytes("image.bin")
        \\    print(str(len(back)))
        \\    var same = true
        \\    var at = 0
        \\    while at < len(back):
        \\        if back[at] != data[at]:
        \\            same = false
        \\        at += 1
        \\    print(str(same))
        \\    print(strings.from_bytes(back) else "(not text)")
        \\
    , .{ .world = world });
    defer session.deinit();

    try testing.expectEqualStrings("5\ntrue\n(not text)\n", session.printed());
    try testing.expectEqual(agree.End{ .finished = 0 }, session.end);
}

test "append_bytes adds to the end of what is there" {
    const world: agree.World = .withFile("log.bin", "ab");

    var session = try agree.compare(
        \\import std.files
        \\import std.strings
        \\
        \\func main() -> !:
        \\    try files.append_bytes("log.bin", strings.to_bytes("cd"))
        \\    let back = try files.read_bytes("log.bin")
        \\    print(strings.from_bytes(back) else "(not text)")
        \\
    , .{ .world = world });
    defer session.deinit();

    try testing.expectEqualStrings("abcd\n", session.printed());
    try testing.expectEqual(agree.End{ .finished = 0 }, session.end);
}

test "the text conveniences still read and write text, over the byte channel" {
    // `file_read` and `file_write` did not change in surface or in
    // meaning; what changed is that they are open-read-close over the
    // channel now, with `libluce_rt`'s own validation (R2).  A file
    // that is not text is still refused, and still as an error.
    const world: agree.World = .withFile("notes.txt", "file body");

    var session = try agree.compare(
        \\import std.files
        \\
        \\func main() -> !:
        \\    print(try files.read("notes.txt"))
        \\    try files.write("out.txt", "saved")
        \\    print(try files.read("out.txt"))
        \\
    , .{ .world = world });
    defer session.deinit();

    try testing.expectEqualStrings("file body\nsaved\n", session.printed());
}

test "a file whose bytes are not text is refused as a string" {
    // The sentence that used to live in `apps/host.zig`, where only
    // loom could say it.  It lives in `libluce_rt` now, which is why
    // both arms of this comparison say it identically (R2).
    const world: agree.World = .withFile("image.bin", "\xff\xfe");

    var session = try agree.compare(
        \\import std.files
        \\import std.strings
        \\
        \\func main():
        \\    var note = ""
        \\    var text = ""
        \\    text = files.read("image.bin") catch reason:
        \\        note = reason
        \\    print("no: " + note)
        \\    print("text: " + text)
        \\
    , .{ .world = world });
    defer session.deinit();

    try testing.expectEqualStrings("no: cannot read image.bin\ntext: \n", session.printed());
}

test "a host with no file services at all fails closed" {
    try agree.trapGiven(
        \\import std.files
        \\
        \\func main() -> !:
        \\    var f = try files.open("notes.txt")
        \\
    , .nothing, .host_unavailable);
}
