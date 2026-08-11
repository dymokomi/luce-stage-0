//! Tagged unions, on both engines (docs/UNION.md).
//!
//! The decisions this file is the executable form of: construction as
//! a namespaced call with named arguments and defaults (D1, D4),
//! `match` as the only door with per-field bindings (D5, D7), payload
//! bindings that alias the scrutinee (D10), ownership with no new rule
//! — `give`/`copy`/`free` on a carrying union, and an error unwinding
//! past one (D9, S34) — the zero as the first declared member with
//! every payload field at its own zero (D13, BYTES B2), recursion
//! through owning containers rather than through the layout (D12),
//! `Shape?` as the recursion terminator that is not a container (D14),
//! `string(u)` as the member's name (D16), and the exhaustive match
//! whose last arm is the fallthrough (A4 via ENUMS R1).
//!
//! Every program here runs twice, interpreted and compiled, and the
//! two are compared on prints, traps, traces and the leak census
//! (`specs/agree.zig`).  The census is the point of half of these: a
//! union value is a struct-shaped run the runtime walks without ever
//! learning unions exist (D8), so a missed release or a double free
//! shows up here as a number rather than in somebody's program.
//!
//! The refusals — D1's positional payload, D2's all-bare union, D3's
//! member-as-type, D5's partial field list, D12's self-containing
//! union, D15's union map key, D16's `==` — are compile-time facts
//! and live where every refusal lives: `03_parse/test.zig` and
//! `compile/test.zig`.  A program that does not compile has no engine
//! to disagree about.

const std = @import("std");
const agree = @import("agree.zig");

// ---------------------------------------------------------------------------
// Construction and dispatch, every member shape
// ---------------------------------------------------------------------------

test "construction and dispatch: bare, single-field, and multi-field members" {
    try agree.ok(
        \\union Shape:
        \\    empty
        \\    circle(radius: double)
        \\    rect(width: double, height: double)
        \\
        \\func area(s: Shape) -> double:
        \\    match s:
        \\        empty:
        \\            return 0.0
        \\        circle(radius):
        \\            return 3.0 * radius * radius
        \\        rect(width, height):
        \\            return width * height
        \\
        \\func main():
        \\    assert(area(Shape.empty) == 0.0)
        \\    assert(area(Shape.circle(radius = 2.0)) == 12.0)
        \\    assert(area(Shape.rect(width = 3.0, height = 4.0)) == 12.0)
        \\
    );
}

test "construction: defaults on payload fields fill the unwritten ones (D4)" {
    try agree.ok(
        \\union Shape:
        \\    empty
        \\    rect(width: double, height: double = 2.0)
        \\
        \\func area(s: Shape) -> double:
        \\    match s:
        \\        empty:
        \\            return 0.0
        \\        rect(width, height):
        \\            return width * height
        \\
        \\func main():
        \\    assert(area(Shape.rect(width = 3.0)) == 6.0)
        \\    assert(area(Shape.rect(width = 3.0, height = 5.0)) == 15.0)
        \\
    );
}

test "dispatch: an arm may name its member bare and bind nothing (D5)" {
    try agree.ok(
        \\union Shape:
        \\    empty
        \\    circle(radius: double)
        \\
        \\func kind(s: Shape) -> long:
        \\    match s:
        \\        empty:
        \\            return 0
        \\        circle:
        \\            return 1
        \\
        \\func main():
        \\    assert(kind(Shape.empty) == 0)
        \\    assert(kind(Shape.circle(radius = 9.0)) == 1)
        \\
    );
}

test "A4: with every member listed the last arm is the fallthrough, and each value lands on its own" {
    try agree.ok(
        \\union Shape:
        \\    empty
        \\    circle(radius: double)
        \\    rect(width: double, height: double)
        \\
        \\func name(s: Shape) -> string:
        \\    match s:
        \\        empty:
        \\            return "empty"
        \\        circle:
        \\            return "circle"
        \\        rect:
        \\            return "rect"
        \\
        \\func main():
        \\    assert(name(Shape.empty) == "empty")
        \\    assert(name(Shape.circle(radius = 1.0)) == "circle")
        \\    assert(name(Shape.rect(width = 1.0, height = 1.0)) == "rect")
        \\
    );
}

// ---------------------------------------------------------------------------
// Payload bindings: a copy of a value, an alias of an object (D10)
// ---------------------------------------------------------------------------

test "D10: a value payload binds as an ordinary copy, per arm and per type" {
    try agree.ok(
        \\union Reading:
        \\    missing
        \\    scalar(value: double)
        \\    labeled(value: string)
        \\
        \\func describe(r: Reading) -> string:
        \\    match r:
        \\        missing:
        \\            return "missing"
        \\        scalar(value):
        \\            return string(value)
        \\        labeled(value):
        \\            return value
        \\
        \\func main():
        \\    assert(describe(Reading.missing) == "missing")
        \\    assert(describe(Reading.scalar(value = 1.5)) == "1.5")
        \\    assert(describe(Reading.labeled(value = "seen")) == "seen")
        \\
    );
}

test "D10: an object payload binds as an alias — mutate through it, observe through the scrutinee" {
    try agree.ok(
        \\union Json:
        \\    null
        \\    array(items: list(long))
        \\
        \\func main():
        \\    let doc = Json.array(items = [1, 2])
        \\    match doc:
        \\        null:
        \\            assert(false)
        \\        array(items):
        \\            items.append(3)
        \\    match doc:
        \\        null:
        \\            assert(false)
        \\        array(items):
        \\            assert(len(items) == 3)
        \\            assert(items[2] == 3)
        \\
    );
}

// ---------------------------------------------------------------------------
// Ownership: give, copy, free, and the unwind (D9, S34)
// ---------------------------------------------------------------------------

test "D9: give moves a carrying union whole, and copy is the deep walk" {
    try agree.ok(
        \\union Json:
        \\    null
        \\    array(items: list(long))
        \\
        \\func count(j: give Json) -> long:
        \\    match j:
        \\        null:
        \\            return 0
        \\        array(items):
        \\            return len(items)
        \\
        \\func main():
        \\    var xs = new list(long)
        \\    xs.append(7)
        \\    var a = Json.array(items = give xs)
        \\    let b = copy a
        \\    assert(count(give a) == 1)
        \\    match b:
        \\        null:
        \\            assert(false)
        \\        array(items):
        \\            assert(len(items) == 1)
        \\            assert(items[0] == 7)
        \\
    );
}

test "D9: scope release frees whichever member a union holds, object-carrying or not" {
    // No `free(u)`: a union takes the verbs a carrying struct takes
    // (D9), and `free` was never one of them — S6 releases a direct
    // container or resource handle, so `free` on a union is refused
    // exactly as it is on a struct (`compile/test.zig`).  What is
    // proven here is the release itself: three members of three
    // shapes go out of scope and the census is zero, so the walk
    // freed the list the `array` member owned and walked past the
    // members that owned nothing.
    try agree.ok(
        \\union Json:
        \\    null
        \\    number(value: double)
        \\    array(items: list(long))
        \\
        \\func main():
        \\    var heavy = Json.array(items = [1, 2, 3])
        \\    var light = Json.number(value = 4.0)
        \\    var bare = Json.null
        \\    match heavy:
        \\        array(items):
        \\            assert(len(items) == 3)
        \\        else:
        \\            assert(false)
        \\
    );
}

test "S34: a caught error unwinds past carrying unions and the census stays clean" {
    try agree.ok(
        \\union Json:
        \\    null
        \\    number(value: double)
        \\    array(items: list(long))
        \\
        \\func risky(ok: bool) -> long!:
        \\    var doc = Json.array(items = [1, 2, 3])
        \\    var extra = Json.number(value = 2.0)
        \\    if not ok:
        \\        error("no reading")
        \\    match doc:
        \\        null:
        \\            return 0
        \\        number(value):
        \\            return long(value)
        \\        array(items):
        \\            return len(items)
        \\
        \\func main():
        \\    let counted = risky(true) catch -1
        \\    assert(counted == 3)
        \\    let caught = risky(false) catch -1
        \\    assert(caught == -1)
        \\
    );
}

test "S34: a trap mid-run aborts cleanly with union values in flight" {
    try agree.trap(
        \\union Json:
        \\    null
        \\    array(items: list(long))
        \\
        \\func main():
        \\    var doc = Json.array(items = [1, 2])
        \\    var xs = [3]
        \\    let bad = xs[9]
        \\
    , .index_bounds);
}

// ---------------------------------------------------------------------------
// The zero: first declared member, every payload field at its own zero
// ---------------------------------------------------------------------------

test "D13: a late var holds the first member with zeroed fields, payload-carrying or not" {
    // Two unions, because D13 has no ordering constraint: the zero is
    // the first declared member whether it is bare or the widest one.
    try agree.ok(
        \\union Shape:
        \\    empty
        \\    circle(radius: double)
        \\
        \\union Reading:
        \\    sample(value: double, count: long)
        \\    missing
        \\
        \\func main():
        \\    var s: Shape
        \\    match s:
        \\        empty:
        \\            assert(true)
        \\        circle:
        \\            assert(false)
        \\    var r: Reading
        \\    match r:
        \\        sample(value, count):
        \\            assert(value == 0.0)
        \\            assert(count == 0)
        \\        missing:
        \\            assert(false)
        \\
    );
}

test "B2: every cell of a new array holds the union's zero, and a cell takes a new value" {
    try agree.ok(
        \\union Shape:
        \\    empty
        \\    circle(radius: double)
        \\    rect(width: double, height: double)
        \\
        \\func kind(s: Shape) -> long:
        \\    match s:
        \\        empty:
        \\            return 0
        \\        circle:
        \\            return 1
        \\        rect:
        \\            return 2
        \\
        \\func main():
        \\    var cells = new array(Shape, 3)
        \\    assert(kind(cells[0]) == 0)
        \\    assert(kind(cells[2]) == 0)
        \\    cells[1] = Shape.circle(radius = 5.0)
        \\    match cells[1]:
        \\        circle(radius):
        \\            assert(radius == 5.0)
        \\        else:
        \\            assert(false)
        \\    assert(kind(cells[0]) == 0)
        \\
    );
}

test "B2: a list of unions is handed the element zero, and elements come back whole" {
    try agree.ok(
        \\union Json:
        \\    null
        \\    number(value: double)
        \\    text(value: string)
        \\
        \\func main():
        \\    var xs = new list(Json)
        \\    xs.append(Json.null)
        \\    xs.append(Json.number(value = 2.5))
        \\    xs.append(Json.text(value = "kept words long enough to own outside bytes"))
        \\    assert(len(xs) == 3)
        \\    match xs[1]:
        \\        number(value):
        \\            assert(value == 2.5)
        \\        else:
        \\            assert(false)
        \\    match xs[2]:
        \\        text(value):
        \\            assert(value == "kept words long enough to own outside bytes")
        \\        else:
        \\            assert(false)
        \\
    );
}

// ---------------------------------------------------------------------------
// Recursion through containers (the std.json shape)
// ---------------------------------------------------------------------------

test "D12: a Json tree builds through containers, walks recursively, and frees clean" {
    try agree.ok(
        \\union Json:
        \\    null
        \\    number(value: double)
        \\    array(items: list(Json))
        \\    object(fields: map(string, Json))
        \\
        \\func total(j: Json) -> double:
        \\    match j:
        \\        null:
        \\            return 0.0
        \\        number(value):
        \\            return value
        \\        array(items):
        \\            var sum: double = 0.0
        \\            for item in items:
        \\                sum = sum + total(item)
        \\            return sum
        \\        object(fields):
        \\            var sum: double = 0.0
        \\            for key in fields.keys():
        \\                let item = fields.get(key)
        \\                if item != none:
        \\                    sum = sum + total(item)
        \\            return sum
        \\
        \\func main():
        \\    var items = new list(Json)
        \\    items.append(Json.number(value = 1.5))
        \\    items.append(Json.number(value = 2.5))
        \\    items.append(Json.null)
        \\    var fields = new map(string, Json)
        \\    fields["values"] = Json.array(items = give items)
        \\    fields["extra"] = Json.number(value = 4.0)
        \\    let doc = Json.object(fields = give fields)
        \\    assert(total(doc) == 8.0)
        \\    let twin = copy doc
        \\    assert(total(twin) == 8.0)
        \\
    );
}

// ---------------------------------------------------------------------------
// Shape?: absence, narrowing, and the unwrap (D14)
// ---------------------------------------------------------------------------

test "D14: a Shape? holds none or a value, narrows on the test, and matches once narrowed" {
    try agree.ok(
        \\union Shape:
        \\    empty
        \\    circle(radius: double)
        \\
        \\func pick(want: bool) -> Shape?:
        \\    if want:
        \\        return Shape.circle(radius = 2.0)
        \\    return none
        \\
        \\func main():
        \\    let got = pick(true)
        \\    if got == none:
        \\        assert(false)
        \\    else:
        \\        match got:
        \\            empty:
        \\                assert(false)
        \\            circle(radius):
        \\                assert(radius == 2.0)
        \\    let missing = pick(false)
        \\    assert(missing == none)
        \\    let fallback = pick(false) else Shape.empty
        \\    match fallback:
        \\        empty:
        \\            assert(true)
        \\        circle:
        \\            assert(false)
        \\    let sure = pick(true) else Shape.empty
        \\    match sure:
        \\        empty:
        \\            assert(false)
        \\        circle(radius):
        \\            assert(radius == 2.0)
        \\
    );
}

// ---------------------------------------------------------------------------
// string(u): the member's name, never the payload (D16)
// ---------------------------------------------------------------------------

test "D16: string(u) answers the member's name for every member" {
    try agree.ok(
        \\union Json:
        \\    null
        \\    boolean(value: bool)
        \\    number(value: double)
        \\    text(value: string)
        \\    array(items: list(Json))
        \\    object(fields: map(string, Json))
        \\
        \\func main():
        \\    assert(string(Json.null) == "null")
        \\    assert(string(Json.boolean(value = true)) == "boolean")
        \\    assert(string(Json.number(value = 3.0)) == "number")
        \\    assert(string(Json.text(value = "words")) == "text")
        \\    assert(string(Json.array(items = new list(Json))) == "array")
        \\    assert(string(Json.object(fields = new map(string, Json))) == "object")
        \\
    );
}
