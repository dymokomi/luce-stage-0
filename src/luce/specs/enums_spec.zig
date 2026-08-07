//! Enums and the match statement, on both engines (docs/ENUMS.md).
//!
//! The decisions this file is the executable form of: the C rule for
//! member values (D1), the backing width (D2), namespaced members (D3),
//! no implicit conversion in either direction (D4), `string(m)` as the
//! member's *name* (D5), equality only (D6), the methods and namespace
//! functions a struct has (D7), members that fold (D8), containers at
//! the backing width (D9), and dispatch that a member added later
//! breaks on purpose (R1) — with `Method(n)` answering `Method?` (R2)
//! and bare member names for arms (R3).
//!
//! Every program here runs twice, interpreted and compiled, and the
//! two are compared on prints, traps, traces and the leak census
//! (`specs/agree.zig`).  What that buys for enums specifically: a
//! member is a constant at its backing width on one engine and an
//! `i8`/`i16`/`i32`/`i64` on the other, and `string(m)` is the same
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
        \\    assert(int(Step.first) == 0)
        \\    assert(int(Step.second) == 1)
        \\    assert(int(Step.third) == 2)
        \\    assert(int(Method.deflated) == 8)
        \\    assert(int(Mixed.a) == 0)
        \\    assert(int(Mixed.b) == 10)
        \\    assert(int(Mixed.c) == 11)
        \\    assert(int(Mixed.d) == -2)
        \\    assert(int(Mixed.e) == -1)
        \\
    );
}

test "members: a value folds like any constant expression" {
    try agree.ok(
        \\let base = 4
        \\
        \\enum Flag:
        \\    none_set = 0
        \\    one = 1 << 0
        \\    two = 1 << 1
        \\    four = base
        \\    eight = base * 2
        \\
        \\func main():
        \\    assert(int(Flag.one) == 1)
        \\    assert(int(Flag.two) == 2)
        \\    assert(int(Flag.four) == 4)
        \\    assert(int(Flag.eight) == 8)
        \\
    );
}

// ---------------------------------------------------------------------------
// The backing width (D2)
// ---------------------------------------------------------------------------

test "backing: every rung of the ladder holds its members" {
    try agree.ok(
        \\enum Small(byte):
        \\    off = 0
        \\    on = 255
        \\
        \\enum Middle(short):
        \\    low = -32768
        \\    high = 32767
        \\
        \\enum Wide(long):
        \\    huge = 9223372036854775807
        \\    tiny = -9223372036854775808
        \\
        \\func main():
        \\    assert(int(Small.on) == 255)
        \\    assert(int(Middle.low) == -32768)
        \\    assert(long(Wide.huge) == 9223372036854775807)
        \\    assert(long(Wide.tiny) == -9223372036854775808)
        \\    assert(Small.on == Small.on)
        \\    assert(Middle.low != Middle.high)
        \\
    );
}

// ---------------------------------------------------------------------------
// Equality, and only equality (D6)
// ---------------------------------------------------------------------------

test "equality: members compare with == and !=, at any width" {
    try agree.ok(
        \\enum Method(byte):
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

test "int(m): the member's number, at every constructor's width" {
    try agree.ok(
        \\enum Method:
        \\    stored = 0
        \\    deflated = 8
        \\
        \\func main():
        \\    let m = Method.deflated
        \\    assert(int(m) == 8)
        \\    assert(long(m) == 8)
        \\    assert(byte(m) == 8)
        \\    assert(short(m) == 8)
        \\    assert(double(m) == 8.0)
        \\    let sum = int(m) + int(Method.stored)
        \\    assert(sum == 8)
        \\
    );
}

test "byte(m): a member past the destination traps like any narrowing" {
    try agree.trap(
        \\enum Big(long):
        \\    small = 1
        \\    huge = 300
        \\
        \\func main():
        \\    var m = Big.small
        \\    m = Big.huge
        \\    assert(byte(m) == 44)
        \\
    , .conversion_range);
}

test "Method(n): a member for a number that is one, none for a number that is not" {
    try agree.ok(
        \\enum Method:
        \\    stored = 0
        \\    deflated = 8
        \\
        \\func read(raw: long) -> string:
        \\    let m = Method(raw)
        \\    if m == none:
        \\        return "unknown"
        \\    return string(m)
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

test "Method(n): a narrow backing is asked about numbers no byte could hold" {
    try agree.ok(
        \\enum Small(byte):
        \\    off = 0
        \\    on = 200
        \\
        \\func main():
        \\    assert(Small(200) != none)
        \\    assert(Small(300) == none)
        \\    assert(Small(-1) == none)
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
        \\func describe(raw: long):
        \\    let kind = Kind(raw)
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
// string(m), and the f-string hole that is one (D5)
// ---------------------------------------------------------------------------

test "string(m): the member's name, from a variable and from a constant" {
    try agree.prints(
        \\enum Method(byte):
        \\    stored = 0
        \\    shrunk = 1
        \\    deflated = 8
        \\
        \\func main():
        \\    print(string(Method.stored))
        \\    print(string(Method.deflated))
        \\    var m = Method.shrunk
        \\    print(string(m))
        \\    print(f"{m} is {int(m)}")
        \\    m = Method.deflated
        \\    print(f"{m} is {int(m)}")
        \\
    ,
        "stored\ndeflated\nshrunk\nshrunk is 1\ndeflated is 8\n",
    );
}

test "string(m): a one-member enum needs no comparison at all" {
    try agree.prints(
        \\enum Only:
        \\    alone
        \\
        \\func main():
        \\    print(string(Only.alone))
        \\
    ,
        "alone\n",
    );
}

test "string(m): the name is a borrow, and a binding that keeps it copies" {
    try agree.ok(
        \\enum Method:
        \\    stored
        \\    deflated
        \\
        \\func main():
        \\    var names = new list(string)
        \\    var m = Method.stored
        \\    names.append(string(m))
        \\    m = Method.deflated
        \\    names.append(string(m))
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
        \\func name(c: Colour) -> string:
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
        \\        let c = Colour(raw) else trap("every raw here is a member")
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
        \\func apply(op: Op, value: long) -> long:
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
        \\            var xs = new list(long)
        \\            xs.append(1)
        \\            assert(len(xs) == 1)
        \\        grid:
        \\            var rows = new list(long)
        \\            rows.append(2)
        \\            rows.append(3)
        \\            assert(len(rows) == 2)
        \\
    );
}

// ---------------------------------------------------------------------------
// Methods and namespace functions (D7)
// ---------------------------------------------------------------------------

test "methods: a method on an enum, called both ways" {
    try agree.ok(
        \\enum Method:
        \\    stored = 0
        \\    deflated = 8
        \\
        \\    func compressed(self) -> bool:
        \\        return self != Method.stored
        \\
        \\    func spelled(self) -> string:
        \\        match self:
        \\            stored:
        \\                return "stored"
        \\            deflated:
        \\                return "deflated"
        \\
        \\    func of(raw: long) -> Method:
        \\        return Method(raw) else Method.stored
        \\
        \\func main():
        \\    let m = Method.deflated
        \\    assert(m.compressed())
        \\    assert(not Method.stored.compressed())
        \\    assert(Method.compressed(m))
        \\    assert(m.spelled() == "deflated")
        \\    assert(Method.of(8) == Method.deflated)
        \\    assert(Method.of(99) == Method.stored)
        \\
    );
}

test "methods: var self writes the receiver back" {
    try agree.ok(
        \\enum Light:
        \\    red
        \\    green
        \\
        \\    func flip(var self):
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
        \\let default_method = Method.deflated
        \\let default_number = int(Method.deflated)
        \\let default_name = string(Method.deflated)
        \\let is_stored = Method.deflated == Method.stored
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
        \\    size: long
        \\    method: Method = Method.stored
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
        \\enum Method(byte):
        \\    stored = 0
        \\    shrunk = 1
        \\    deflated = 8
        \\
        \\struct Entry:
        \\    method: Method
        \\
        \\func main():
        \\    var methods = new list(Method)
        \\    methods.append(Method.stored)
        \\    methods.append(Method.deflated)
        \\    assert(len(methods) == 2)
        \\    assert(methods[0] == Method.stored)
        \\    assert(methods[1] == Method.deflated)
        \\
        \\    var counts = new map(string, Method)
        \\    counts["a"] = Method.deflated
        \\    assert(counts.has("a"))
        \\    assert(counts["a"] == Method.deflated)
        \\
        \\    var grid = new array(Method, 3)
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

test "containers: an array of enums fills with the first member" {
    try agree.ok(
        \\enum Cell(byte):
        \\    empty = 0
        \\    wall = 1
        \\
        \\func main():
        \\    var grid = new array(Cell, 2, 2)
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
        \\func both() -> (Method, long):
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
