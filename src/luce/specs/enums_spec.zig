//! Enums and the match statement, on both engines (docs/ENUMS.md).
//!
//! The decisions this file is the executable form of: the C rule for
//! member values (D1), the backing width (D2), namespaced members (D3),
//! no implicit conversion in either direction (D4), `str(m)` as the
//! member's *name* (D5), equality only (D6), the methods and namespace
//! functions a struct has (D7), members that fold (D8), containers at
//! the backing width (D9), and dispatch that a member added later
//! breaks on purpose (R1) — with `Method(n)` answering `Method?` (R2)
//! and bare member names for arms (R3).
//!
//! Every program here runs twice, interpreted and compiled, and the
//! two are compared on prints, traps, traces and the leak census
//! (`specs/agree.zig`).  What that buys for enums specifically: a
//! member is a constant at its backing width on one engine and the
//! matching explicit-width integer on the other, and `str(m)` is the same
//! compare-and-branch tree on both — so a disagreement about a width
//! or a name shows up here rather than in somebody's program.

const std = @import("std");
const agree = @import("agree.zig");

// ---------------------------------------------------------------------------
// Members: the C rule, verbatim
// ---------------------------------------------------------------------------

test "members: sequential from zero, explicit where written, and both at once" {
    try agree.ok(
        \\enum Step:
        \\    first
        \\    second
        \\    third
        \\
        \\enum Method:
        \\    stored = 0
        \\    shrunk = 1
        \\    deflated = 8
        \\
        \\enum Mixed:
        \\    a
        \\    b = 10
        \\    c
        \\    d = -2
        \\    e
        \\
        \\func main():
        \\    assert(i32(Step.first) == 0)
        \\    assert(i32(Step.second) == 1)
        \\    assert(i32(Step.third) == 2)
        \\    assert(i32(Method.deflated) == 8)
        \\    assert(i32(Mixed.a) == 0)
        \\    assert(i32(Mixed.b) == 10)
        \\    assert(i32(Mixed.c) == 11)
        \\    assert(i32(Mixed.d) == -2)
        \\    assert(i32(Mixed.e) == -1)
        \\
    );
}

test "members: a value folds like any constant expression" {
    try agree.ok(
        \\const base = 4
        \\
        \\enum Flag:
        \\    none_set = 0
        \\    one = 1 << 0
        \\    two = 1 << 1
        \\    four = base
        \\    eight = base * 2
        \\
        \\func main():
        \\    assert(i32(Flag.one) == 1)
        \\    assert(i32(Flag.two) == 2)
        \\    assert(i32(Flag.four) == 4)
        \\    assert(i32(Flag.eight) == 8)
        \\
    );
}

// ---------------------------------------------------------------------------
// The backing width (D2)
// ---------------------------------------------------------------------------

test "backing: every explicit integer width holds its members" {
    try agree.ok(
        \\enum U8Kind(u8):
        \\    low = 0
        \\    high = 255
        \\
        \\enum U16Kind(u16):
        \\    low = 0
        \\    high = 65535
        \\
        \\enum U32Kind(u32):
        \\    low = 0
        \\    high = 4294967295
        \\
        \\enum U64Kind(u64):
        \\    low = 0
        \\    high = 18446744073709551615
        \\
        \\enum I8Kind(i8):
        \\    low = -128
        \\    high = 127
        \\
        \\enum I16Kind(i16):
        \\    low = -32768
        \\    high = 32767
        \\
        \\enum I32Kind(i32):
        \\    low = -2147483648
        \\    high = 2147483647
        \\
        \\enum I64Kind(i64):
        \\    low = -9223372036854775808
        \\    high = 9223372036854775807
        \\
        \\func main():
        \\    assert(u8(U8Kind.high) == 255)
        \\    assert(u16(U16Kind.high) == 65535)
        \\    assert(u32(U32Kind.high) == 4294967295)
        \\    assert(u64(U64Kind.high) == 18446744073709551615)
        \\    assert(i8(I8Kind.low) == -128)
        \\    assert(i16(I16Kind.low) == -32768)
        \\    assert(i32(I32Kind.low) == -2147483648)
        \\    assert(i64(I64Kind.low) == -9223372036854775808)
        \\    assert(U8Kind.high == U8Kind.high)
        \\    assert(I16Kind.low != I16Kind.high)
        \\
    );
}

// ---------------------------------------------------------------------------
// Equality, and only equality (D6)
// ---------------------------------------------------------------------------

test "equality: members compare with == and !=, at any width" {
    try agree.ok(
        \\enum Method(u8):
        \\    stored = 0
        \\    deflated = 8
        \\
        \\func same(a: Method, b: Method) -> bool:
        \\    return a == b
        \\
        \\func main():
        \\    var m = Method.stored
        \\    assert(m == Method.stored)
        \\    assert(m != Method.deflated)
        \\    m = Method.deflated
        \\    assert(m == Method.deflated)
        \\    assert(same(m, Method.deflated))
        \\    assert(not same(m, Method.stored))
        \\
    );
}

// ---------------------------------------------------------------------------
// Conversions, both directions (D4, R2)
// ---------------------------------------------------------------------------

test "explicit numeric conversions read an enum member at every width" {
    try agree.ok(
        \\enum Method:
        \\    stored = 0
        \\    deflated = 8
        \\
        \\func main():
        \\    let m = Method.deflated
        \\    assert(i32(m) == 8)
        \\    assert(i64(m) == 8)
        \\    assert(u8(m) == 8)
        \\    assert(i16(m) == 8)
        \\    assert(f64(m) == 8.0)
        \\    let sum = i32(m) + i32(Method.stored)
        \\    assert(sum == 8)
        \\
    );
}

test "u8(m): a member past the destination traps like any narrowing" {
    try agree.trap(
        \\enum Big(i64):
        \\    small = 1
        \\    huge = 300
        \\
        \\func main():
        \\    var m = Big.small
        \\    m = Big.huge
        \\    assert(u8(m) == 44)
        \\
    , .conversion_range);
}

test "Method(n): a member for a number that is one, none for a number that is not" {
    try agree.ok(
        \\enum Method:
        \\    stored = 0
        \\    deflated = 8
        \\
        \\func read(raw: i64) -> str:
        \\    let m = Method(i32(raw))
        \\    if m == none:
        \\        return "unknown"
        \\    return str(m)
        \\
        \\func main():
        \\    assert(Method(0) != none)
        \\    assert(Method(8) != none)
        \\    assert(Method(3) == none)
        \\    assert(Method(-1) == none)
        \\    assert(read(0) == "stored")
        \\    assert(read(8) == "deflated")
        \\    assert(read(9) == "unknown")
        \\
    );
}

test "Method(n): a narrow backing returns none for an unused representable value" {
    try agree.ok(
        \\enum Small(u8):
        \\    off = 0
        \\    on = 200
        \\
        \\func main():
        \\    assert(Small(200) != none)
        \\    assert(Small(2) == none)
        \\    let found = Small(200)
        \\    if found != none:
        \\        assert(found == Small.on)
        \\
    );
}

test "Method(n): the answer narrows and is then a member like any other" {
    try agree.prints(
        \\enum Kind:
        \\    stored = 0
        \\    fixed = 1
        \\    dynamic = 2
        \\
        \\func describe(raw: i64):
        \\    let kind = Kind(i32(raw))
        \\    if kind == none:
        \\        print("unknown block")
        \\        return
        \\    match kind:
        \\        stored:
        \\            print("stored block")
        \\        fixed:
        \\            print("fixed block")
        \\        dynamic:
        \\            print("dynamic block")
        \\
        \\func main():
        \\    describe(0)
        \\    describe(1)
        \\    describe(2)
        \\    describe(3)
        \\
    ,
        "stored block\nfixed block\ndynamic block\nunknown block\n",
    );
}

// ---------------------------------------------------------------------------
// str(m), and the f-string hole that is one (D5)
// ---------------------------------------------------------------------------

test "str(m): the member's name, from a variable and from a constant" {
    try agree.prints(
        \\enum Method(u8):
        \\    stored = 0
        \\    shrunk = 1
        \\    deflated = 8
        \\
        \\func main():
        \\    print(str(Method.stored))
        \\    print(str(Method.deflated))
        \\    var m = Method.shrunk
        \\    print(str(m))
        \\    print(f"{m} is {i32(m)}")
        \\    m = Method.deflated
        \\    print(f"{m} is {i32(m)}")
        \\
    ,
        "stored\ndeflated\nshrunk\nshrunk is 1\ndeflated is 8\n",
    );
}

test "str(m): a one-member enum needs no comparison at all" {
    try agree.prints(
        \\enum Only:
        \\    alone
        \\
        \\func main():
        \\    print(str(Only.alone))
        \\
    ,
        "alone\n",
    );
}

test "str(m): the name is a borrow, and a binding that keeps it copies" {
    try agree.ok(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\func main():
        \\    var names = list[str]()
        \\    var m = Method.stored
        \\    names.append(str(m))
        \\    m = Method.deflated
        \\    names.append(str(m))
        \\    assert(len(names) == 2)
        \\    assert(names[0] == "stored")
        \\    assert(names[1] == "deflated")
        \\
    );
}

// ---------------------------------------------------------------------------
// match (R1, R3)
// ---------------------------------------------------------------------------

test "match: every member named, and the arm that runs is the one that matched" {
    try agree.prints(
        \\enum Colour:
        \\    red
        \\    green
        \\    blue
        \\
        \\func name(c: Colour) -> str:
        \\    match c:
        \\        red:
        \\            return "red"
        \\        green:
        \\            return "green"
        \\        blue:
        \\            return "blue"
        \\
        \\func main():
        \\    print(name(Colour.red))
        \\    print(name(Colour.green))
        \\    print(name(Colour.blue))
        \\
    ,
        "red\ngreen\nblue\n",
    );
}

test "match: an else stands for every member the arms did not name" {
    try agree.prints(
        \\enum Colour:
        \\    red
        \\    green
        \\    blue
        \\
        \\func main():
        \\    for raw in range(0, 3):
        \\        let c = Colour(i32(raw)) else trap("every raw here is a member")
        \\        match c:
        \\            green:
        \\                print("green")
        \\            else:
        \\                print("not green")
        \\
    ,
        "not green\ngreen\nnot green\n",
    );
}

test "match: arms are statements, so they assign, loop, break and return" {
    try agree.ok(
        \\enum Op:
        \\    add
        \\    twice
        \\    stop
        \\
        \\func apply(op: Op, value: i64) -> i64:
        \\    var total = value
        \\    match op:
        \\        add:
        \\            var step = 0
        \\            while step < 3:
        \\                total = total + 1
        \\                step = step + 1
        \\        twice:
        \\            total = total * 2
        \\        stop:
        \\            return 0
        \\    return total
        \\
        \\func main():
        \\    assert(apply(Op.add, 1) == 4)
        \\    assert(apply(Op.twice, 5) == 10)
        \\    assert(apply(Op.stop, 7) == 0)
        \\
    );
}

test "match: one inside another, over two enums" {
    try agree.prints(
        \\enum Outer:
        \\    left
        \\    right
        \\
        \\enum Inner:
        \\    up
        \\    down
        \\
        \\func main():
        \\    var a = Outer.left
        \\    var b = Inner.down
        \\    match a:
        \\        left:
        \\            match b:
        \\                up:
        \\                    print("left up")
        \\                down:
        \\                    print("left down")
        \\        right:
        \\            print("right")
        \\
    ,
        "left down\n",
    );
}

test "match: it frees what its arms own, on the arm that runs and the ones that do not" {
    try agree.ok(
        \\enum Shape:
        \\    line
        \\    grid
        \\
        \\func main():
        \\    var s = Shape.grid
        \\    match s:
        \\        line:
        \\            var xs = list[i64]()
        \\            xs.append(1)
        \\            assert(len(xs) == 1)
        \\        grid:
        \\            var rows = list[i64]()
        \\            rows.append(2)
        \\            rows.append(3)
        \\            assert(len(rows) == 2)
        \\
    );
}

// ---------------------------------------------------------------------------
// Methods and namespace functions (D7)
// ---------------------------------------------------------------------------

test "methods: implied-self methods and a static enum function" {
    try agree.ok(
        \\enum Method:
        \\    stored = 0
        \\    deflated = 8
        \\
        \\    func compressed() -> bool:
        \\        return self != Method.stored
        \\
        \\    func spelled() -> str:
        \\        match self:
        \\            stored:
        \\                return "stored"
        \\            deflated:
        \\                return "deflated"
        \\
        \\    static func of(raw: i64) -> Method:
        \\        return Method(i32(raw)) else Method.stored
        \\
        \\func main():
        \\    let m = Method.deflated
        \\    assert(m.compressed())
        \\    assert(not Method.stored.compressed())
        \\    assert(m.spelled() == "deflated")
        \\    assert(Method.of(8) == Method.deflated)
        \\    assert(Method.of(99) == Method.stored)
        \\
    );
}

test "methods: a whole-self enum write is inferred" {
    try agree.ok(
        \\enum Light:
        \\    red
        \\    green
        \\
        \\    func flip():
        \\        match self:
        \\            red:
        \\                self = Light.green
        \\            green:
        \\                self = Light.red
        \\
        \\func main():
        \\    var light = Light.red
        \\    light.flip()
        \\    assert(light == Light.green)
        \\    light.flip()
        \\    assert(light == Light.red)
        \\
    );
}

// ---------------------------------------------------------------------------
// Folding (D8)
// ---------------------------------------------------------------------------

test "folding: a member is a top-level constant, and reads as one" {
    try agree.ok(
        \\enum Method:
        \\    stored = 0
        \\    deflated = 8
        \\
        \\const default_method = Method.deflated
        \\const default_number = i32(Method.deflated)
        \\const default_name = str(Method.deflated)
        \\const is_stored = Method.deflated == Method.stored
        \\
        \\func main():
        \\    assert(default_method == Method.deflated)
        \\    assert(default_number == 8)
        \\    assert(default_name == "deflated")
        \\    assert(not is_stored)
        \\
    );
}

test "folding: a member is a parameter's default and a field's" {
    try agree.ok(
        \\enum Method:
        \\    stored = 0
        \\    deflated = 8
        \\
        \\struct Entry:
        \\    let size: i64
        \\    var method: Method = Method.stored
        \\
        \\func made(method: Method = Method.deflated) -> Method:
        \\    return method
        \\
        \\func main():
        \\    let plain = Entry(size = 3)
        \\    assert(plain.method == Method.stored)
        \\    let written = Entry(size = 3, method = Method.deflated)
        \\    assert(written.method == Method.deflated)
        \\    assert(made() == Method.deflated)
        \\    assert(made(Method.stored) == Method.stored)
        \\
    );
}

// ---------------------------------------------------------------------------
// Containers (D9)
// ---------------------------------------------------------------------------

test "containers: a list, a map, an array and a struct field all hold members" {
    try agree.ok(
        \\enum Method(u8):
        \\    stored = 0
        \\    shrunk = 1
        \\    deflated = 8
        \\
        \\struct Entry:
        \\    var method: Method
        \\
        \\func main():
        \\    var methods = list[Method]()
        \\    methods.append(Method.stored)
        \\    methods.append(Method.deflated)
        \\    assert(len(methods) == 2)
        \\    assert(methods[0] == Method.stored)
        \\    assert(methods[1] == Method.deflated)
        \\
        \\    var counts = map[str, Method]()
        \\    counts["a"] = Method.deflated
        \\    assert(counts.has("a"))
        \\    assert(counts["a"] == Method.deflated)
        \\
        \\    var grid = array[Method](3)
        \\    assert(grid[0] == Method.stored)
        \\    grid[2] = Method.shrunk
        \\    assert(grid[2] == Method.shrunk)
        \\
        \\    let entry = Entry(method = Method.deflated)
        \\    assert(entry.method == Method.deflated)
        \\
        \\    var seen = 0
        \\    for m in methods:
        \\        if m == Method.deflated:
        \\            seen = seen + 1
        \\    assert(seen == 1)
        \\
    );
}

// ---------------------------------------------------------------------------
// A map keyed by an enum (D9, As built 2026-08-12)
// ---------------------------------------------------------------------------
//
// An enum is an integer at a chosen width whose entire comparison
// surface is equality, which is exactly and only what a key needs.  It
// reaches `libluce_rt` as the integer a `i64` key would be
// (`mir.mapKeyStorage`) and comes back narrowed to its own width, so the
// runtime hashes and compares the two payloads it always did — and these
// rows are what prove the round trip on *both* engines, where a widening
// one engine made and the other did not would show up as a lookup that
// finds nothing.

test "a map keys by an enum: put, get, has, remove, and absence" {
    try agree.ok(
        \\enum Key:
        \\    left
        \\    right
        \\    up
        \\    down
        \\
        \\func main():
        \\    var counts = map[Key, i64]()
        \\    counts[Key.left] = 3
        \\    counts[Key.right] = 4
        \\    counts[Key.left] = counts[Key.left] + 1
        \\    assert(counts[Key.left] == 4)
        \\    # A compound store defines the entry it misses, at the
        \\    # value type's zero, keyed by the member.
        \\    counts[Key.up] += 7
        \\    assert(counts[Key.up] == 7)
        \\    counts[Key.up] += 1
        \\    assert(counts[Key.up] == 8)
        \\    counts.remove(Key.up)
        \\    assert(counts[Key.right] == 4)
        \\    assert(len(counts) == 2)
        \\    assert(counts.has(Key.left))
        \\    assert(not counts.has(Key.down))
        \\    assert((counts.get(Key.left) else 0) == 4)
        \\    assert(counts.get(Key.down) == none)
        \\    counts.remove(Key.right)
        \\    assert(not counts.has(Key.right))
        \\    assert(len(counts) == 1)
        \\
    );
}

test "a key comes back out as the enum it went in as" {
    // The honest half of the feature: a key that went in a `Key` and
    // came back a `i64` would be the representation leaking.  The loop
    // name and every element of `keys()` land on `Key`-typed places and
    // are dispatched on with `match`, neither of which a `i64` compiles
    // into — and the order is the insertion order `for` promises.
    try agree.prints(
        \\enum Key:
        \\    left
        \\    right
        \\    up
        \\
        \\func named(k: Key) -> str:
        \\    match k:
        \\        left:
        \\            return "left"
        \\        right:
        \\            return "right"
        \\        up:
        \\            return "up"
        \\
        \\func main():
        \\    var counts = map[Key, i64]()
        \\    counts[Key.up] = 1
        \\    counts[Key.left] = 2
        \\    counts[Key.right] = 3
        \\    for k in counts:
        \\        let held: Key = k
        \\        print(f"{named(held)}={counts[held]}")
        \\    let keys: list[Key] = counts.keys()
        \\    assert(len(keys) == 3)
        \\    assert(keys[0] == Key.up)
        \\    assert(keys[2] == Key.right)
        \\    for k in keys:
        \\        print(str(k))
        \\    for k, count in counts:
        \\        print(f"{str(k)} {count}")
        \\
    ,
        \\up=1
        \\left=2
        \\right=3
        \\up
        \\left
        \\right
        \\up 1
        \\left 2
        \\right 3
        \\
    );
}

test "a key round trip survives every backing width, negative members included" {
    // The widening is a `zext` for `u8` and a `sext` for the other
    // three (docs/TYPES.md D4), and the narrowing back is a truncation:
    // a member at -2 that came back as 4294967294 would fail here.
    try agree.ok(
        \\enum Small(u8):
        \\    zero = 0
        \\    high = 255
        \\
        \\enum Signed(i16):
        \\    low = -32768
        \\    minus = -2
        \\    top = 32767
        \\
        \\enum Wide(i64):
        \\    far = 4294967296
        \\    near = 1
        \\
        \\func main():
        \\    var small = map[Small, i64]()
        \\    small[Small.high] = 1
        \\    assert(small.has(Small.high))
        \\    assert(not small.has(Small.zero))
        \\    for k in small:
        \\        assert(k == Small.high)
        \\
        \\    var signed = map[Signed, str]()
        \\    signed[Signed.low] = "low"
        \\    signed[Signed.minus] = "minus"
        \\    signed[Signed.top] = "top"
        \\    assert(signed[Signed.minus] == "minus")
        \\    assert(len(signed.keys()) == 3)
        \\    for k in signed.keys():
        \\        assert(signed.has(k))
        \\
        \\    var wide = map[Wide, i64]()
        \\    wide[Wide.far] = 7
        \\    assert(wide[Wide.far] == 7)
        \\    assert(not wide.has(Wide.near))
        \\
    );
}

test "a map keyed by one enum holds another" {
    try agree.prints(
        \\enum Key:
        \\    left
        \\    right
        \\
        \\enum Intent:
        \\    move_left
        \\    move_right
        \\    nothing
        \\
        \\func main():
        \\    var bound = map[Key, Intent]()
        \\    bound[Key.left] = Intent.move_left
        \\    bound[Key.right] = Intent.move_right
        \\    for k in bound:
        \\        let intent = bound[k]
        \\        print(f"{str(k)} -> {str(intent)}")
        \\    assert((bound.get(Key.left) else Intent.nothing) == Intent.move_left)
        \\
    ,
        \\left -> move_left
        \\right -> move_right
        \\
    );
}

test "a const keymap lives in the program root, keyed by the enum" {
    // The keymap docs/TERMUI.md D10 had to write with `i32(...)` at
    // every row and every lookup, written the way it reads.
    try agree.prints(
        \\enum Key:
        \\    left
        \\    right
        \\    up
        \\    down
        \\
        \\enum Intent:
        \\    move_left
        \\    move_right
        \\    nothing
        \\
        \\const bindings = {Key.left: Intent.move_left, Key.right: Intent.move_right}
        \\
        \\func intent(k: Key) -> Intent:
        \\    return bindings.get(k) else Intent.nothing
        \\
        \\func main():
        \\    assert(intent(Key.left) == Intent.move_left)
        \\    assert(intent(Key.up) == Intent.nothing)
        \\    assert(bindings.has(Key.right))
        \\    assert(len(bindings) == 2)
        \\    for k in bindings:
        \\        let held: Key = k
        \\        print(f"{str(held)} {str(bindings[held])}")
        \\
    ,
        \\left move_left
        \\right move_right
        \\
    );
}

test "constant enum maps preserve all eight backing-width tags" {
    try agree.ok(
        \\enum U8Key(u8):
        \\    value = 255
        \\enum U16Key(u16):
        \\    value = 65535
        \\enum U32Key(u32):
        \\    value = 4294967295
        \\enum U64Key(u64):
        \\    value = 18446744073709551615
        \\enum I8Key(i8):
        \\    value = -128
        \\enum I16Key(i16):
        \\    value = -32768
        \\enum I32Key(i32):
        \\    value = -2147483648
        \\enum I64Key(i64):
        \\    value = -9223372036854775808
        \\
        \\const U8_MAP = {U8Key.value: "u8"}
        \\const U16_MAP = {U16Key.value: "u16"}
        \\const U32_MAP = {U32Key.value: "u32"}
        \\const U64_MAP = {U64Key.value: "u64"}
        \\const I8_MAP = {I8Key.value: "i8"}
        \\const I16_MAP = {I16Key.value: "i16"}
        \\const I32_MAP = {I32Key.value: "i32"}
        \\const I64_MAP = {I64Key.value: "i64"}
        \\
        \\func main():
        \\    assert(U8_MAP[U8Key.value] == "u8" and U8_MAP.has(U8Key.value))
        \\    assert(U16_MAP[U16Key.value] == "u16" and U16_MAP.has(U16Key.value))
        \\    assert(U32_MAP[U32Key.value] == "u32" and U32_MAP.has(U32Key.value))
        \\    assert(U64_MAP[U64Key.value] == "u64" and U64_MAP.has(U64Key.value))
        \\    assert(I8_MAP[I8Key.value] == "i8" and I8_MAP.has(I8Key.value))
        \\    assert(I16_MAP[I16Key.value] == "i16" and I16_MAP.has(I16Key.value))
        \\    assert(I32_MAP[I32Key.value] == "i32" and I32_MAP.has(I32Key.value))
        \\    assert(I64_MAP[I64Key.value] == "i64" and I64_MAP.has(I64Key.value))
        \\    assert(U64_MAP.keys()[0] == U64Key.value)
        \\    assert(I64_MAP.keys()[0] == I64Key.value)
        \\
    );
}

test "a runtime map literal keyed by enum members" {
    try agree.ok(
        \\enum Key:
        \\    left
        \\    right
        \\
        \\func main():
        \\    var counts = {Key.left: 1, Key.right: 2}
        \\    assert(counts[Key.right] == 2)
        \\    counts[Key.left] = 9
        \\    assert(counts[Key.left] == 9)
        \\
    );
}

test "an enum-keyed map of lists is built and read" {
    // An enum key is a number, and the map holds a list per key.
    try agree.ok(
        \\enum Key:
        \\    left
        \\    right
        \\    up
        \\
        \\func main():
        \\    var runs = map[Key, list[i64]]()
        \\    runs[Key.left] = list[i64]()
        \\    runs[Key.left].append(1)
        \\    runs[Key.left].append(2)
        \\    runs[Key.up] = list[i64]()
        \\    runs[Key.up].append(3)
        \\    assert(len(runs[Key.left]) == 2)
        \\    assert(runs[Key.left][1] == 2)
        \\    var total: i64 = 0
        \\    for k in runs:
        \\        for held in runs[k]:
        \\            total = total + held
        \\    assert(total == 6)
        \\    runs.remove(Key.up)
        \\    assert(len(runs) == 1)
        \\
    );
}

test "containers: an array of enums fills with the first member" {
    try agree.ok(
        \\enum Cell(u8):
        \\    empty = 0
        \\    wall = 1
        \\
        \\func main():
        \\    var grid = array[Cell](2, 2)
        \\    assert(grid[0, 0] == Cell.empty)
        \\    assert(grid[1, 1] == Cell.empty)
        \\    grid[1, 0] = Cell.wall
        \\    assert(grid[1, 0] == Cell.wall)
        \\    assert(grid[0, 1] == Cell.empty)
        \\
    );
}

test "a late var starts at the first member and is assigned over" {
    try agree.ok(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\func main():
        \\    var m: Method
        \\    assert(m == Method.stored)
        \\    m = Method.deflated
        \\    assert(m == Method.deflated)
        \\
    );
}

// ---------------------------------------------------------------------------
// An enum crossing every seam a value crosses
// ---------------------------------------------------------------------------

test "an enum is a parameter, a result, a multiple result, and a T?" {
    try agree.ok(
        \\enum Method:
        \\    stored = 0
        \\    deflated = 8
        \\
        \\func both() -> (Method, i64):
        \\    return Method.deflated, 3
        \\
        \\func passed(m: Method) -> Method:
        \\    return m
        \\
        \\func maybe(want: bool) -> Method?:
        \\    if want:
        \\        return Method.deflated
        \\    return none
        \\
        \\func main():
        \\    let m, size = both()
        \\    assert(m == Method.deflated)
        \\    assert(size == 3)
        \\    assert(passed(Method.stored) == Method.stored)
        \\    let there = maybe(true)
        \\    assert(there != none)
        \\    if there != none:
        \\        assert(there == Method.deflated)
        \\    assert(maybe(false) == none)
        \\    assert((maybe(false) else Method.stored) == Method.stored)
        \\
    );
}

test "an enum survives a fallible call's branch" {
    try agree.ok(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\func chosen(ok: bool) -> Method!:
        \\    if not ok:
        \\        error("no method")
        \\    return Method.deflated
        \\
        \\func main():
        \\    let m = chosen(true) catch Method.stored
        \\    assert(m == Method.deflated)
        \\    let fallback = chosen(false) catch Method.stored
        \\    assert(fallback == Method.stored)
        \\
    );
}

test "one arm names several members, and the rest keep their own" {
    // `block, loop:` — one arm covering several members (docs/ENUMS.md).
    // The multi-member arm and a single-member arm mix, and an arm with
    // several members still counts toward exhaustiveness, so no else is
    // needed when the arms name every member.  Both engines.
    try agree.prints(
        \\enum Node:
        \\    block
        \\    loop
        \\    leaf
        \\    call
        \\
        \\func kind(n: Node) -> str:
        \\    match n:
        \\        block, loop:
        \\            return "control"
        \\        leaf:
        \\            return "leaf"
        \\        call:
        \\            return "call"
        \\
        \\func main():
        \\    print(kind(Node.block))
        \\    print(kind(Node.loop))
        \\    print(kind(Node.leaf))
        \\    print(kind(Node.call))
        \\
    ,
        \\control
        \\control
        \\leaf
        \\call
        \\
    );
}

test "a multi-member arm as the exhaustive tail needs no else" {
    try agree.ok(
        \\enum Signal:
        \\    go
        \\    stop
        \\    wait
        \\
        \\func weight(s: Signal) -> i64:
        \\    match s:
        \\        go:
        \\            return 1
        \\        stop, wait:
        \\            return 2
        \\
        \\func main():
        \\    assert(weight(Signal.go) == 1)
        \\    assert(weight(Signal.stop) == 2)
        \\    assert(weight(Signal.wait) == 2)
        \\
    );
}
