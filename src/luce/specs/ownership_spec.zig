//! The executable specification of docs/OWNERSHIP.md.
//!
//! One test (or a small cluster) per ratified situation S1-S43,
//! numbered to match the document.  Each situation is proven three
//! ways where it applies: the behavior works, misuse is a compile
//! error with the stable code `luce.sema.own`, and the dynamic
//! backstops trap with stable codes.  Every successful run must end
//! with zero live objects — S33 says nothing can leak.
//!
//! The runs happen on **both** engines and are compared: the same
//! printed bytes, the same trap code and words, the same call trace,
//! and the same census (`specs/agree.zig`).  Ownership is the one
//! part of the language where the two implementations could most
//! plausibly drift — a release the lowering skipped is a leak, one it
//! did twice is a double free — so a disagreement here is exactly the
//! bug this suite exists to catch.

const std = @import("std");
const agree = @import("agree.zig");
const luce = @import("luce");
const mir = luce.mir;
const types = luce.types;

const testing = std.testing;

const script: types.CompileOptions = .{};

/// The depth this suite has always run at.
const budget: agree.Provided = .{ .call_depth = 256 };

/// The program runs on both engines, they agree, and nothing is left
/// alive (S33).
fn agreeClean(source: []const u8) !void {
    return agree.okGiven(source, budget);
}

/// Both engines abort the run with exactly `code`, at the same place.
fn agreeTrap(source: []const u8, code: mir.TrapCode) !void {
    return agree.trapGiven(source, budget, code);
}

/// The program is rejected with the stable ownership code — no engine
/// involved, because nothing was produced to run.
fn expectRejected(source: []const u8) !void {
    var result = try luce.compile.compile(testing.allocator, source, script);
    defer result.deinit();
    if (result == .success) {
        std.debug.print("expected an ownership error, but this compiled:\n{s}", .{source});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("luce.sema.own", result.failure.at(0).?.code);
}

// ---------------------------------------------------------------------------
// A. Creating and dropping (S1-S7)
// ---------------------------------------------------------------------------

test "S1: a fresh object bound to a name frees at scope end, no memory words" {
    try agreeClean(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    xs.append(4)
        \\    assert(len(xs) == 4)
        \\    var ages = new Map(String, Int)
        \\    ages["ada"] = 36
        \\    var grid = new Array(Int, 4, 4)
        \\    grid.fill(7)
        \\    var text = new Builder()
        \\    text.append("hello")
        \\    assert(str(text) == "hello")
        \\
    );
}

test "S2: an inner block's object dies at that block's end" {
    // The alias var re-pointed inside the block observes the death.
    try agreeTrap(
        \\func main():
        \\    var outer = [0]
        \\    var view = outer
        \\    if true:
        \\        var inner = [1, 2]
        \\        view = inner
        \\        assert(view[0] == 1)
        \\    let bad = view[0]
        \\
    , .use_after_free);
}

test "S2: an object given out of the block survives it" {
    try agreeClean(
        \\func main():
        \\    var sink = new List(List(Int))
        \\    if true:
        \\        var inner = [7]
        \\        sink.append(give inner)
        \\    assert(len(sink[0]) == 1)
        \\
    );
}

test "S3: unbound temporaries die at the end of their statement" {
    try agreeClean(
        \\import std.strings
        \\
        \\func main():
        \\    var seen = 0
        \\    for word in "a b c".split(""):
        \\        seen = seen + len(word)
        \\    assert(seen == 3)
        \\    assert(len("xy z".split(" ")) == 2)
        \\    assert(len("1,2,3".split(",")[1:]) == 2)
        \\
    );
}

test "S4: return, break, and continue unwind what their scopes own" {
    try agreeClean(
        \\func early(flag: Bool) -> String:
        \\    var lines = ["a", "b"]
        \\    if flag:
        \\        return "early"
        \\    lines.append("c")
        \\    return "late"
        \\
        \\func main():
        \\    assert(early(true) == "early")
        \\    assert(early(false) == "late")
        \\    for i in range(0, 5):
        \\        var row = [i]
        \\        if i == 3:
        \\            break
        \\        var wide = new Array(Int, 8)
        \\        wide.fill(i)
        \\        if i == 1:
        \\            continue
        \\        var tail = new Builder()
        \\        tail.append(str(i))
        \\
    );
}

test "S5: reassigning an owning var frees the old object immediately" {
    try agreeTrap(
        \\func main():
        \\    var xs = [1]
        \\    let view = xs
        \\    xs = [2, 3]
        \\    let bad = view[0]
        \\
    , .use_after_free);
}

test "S5: the life.luc pattern — reassign in a loop, no free dance" {
    try agreeClean(
        \\func step(grid: Array(Int, _)) -> Array(Int, _):
        \\    var next = new Array(Int, len(grid))
        \\    for i in range(0, len(grid)):
        \\        next[i] = grid[i] + 1
        \\    return next
        \\
        \\func main():
        \\    var grid = new Array(Int, 16)
        \\    for tick in range(0, 100):
        \\        grid = step(grid)
        \\    assert(grid[0] == 100)
        \\
    );
}

test "S5: assigning a bare name into an owning var is a compile error" {
    try expectRejected(
        \\func main():
        \\    var xs = [1]
        \\    var ys = [2]
        \\    xs = ys
        \\
    );
}

test "S6: free is early release and poisons the name" {
    try agreeClean(
        \\import std.strings
        \\
        \\func main():
        \\    var big = "a b c d".split(" ")
        \\    let count = len(big)
        \\    free(big)
        \\    assert(count == 4)
        \\
    );
    try expectRejected(
        \\func main():
        \\    var big = [1, 2]
        \\    free(big)
        \\    let bad = big[0]
        \\
    );
}

test "S6: free applies to owned names only" {
    // An alias cannot free.
    try expectRejected(
        \\func main():
        \\    var xs = [1]
        \\    let view = xs
        \\    free(view)
        \\
    );
    // Neither can an arbitrary expression.
    try expectRejected(
        \\func main():
        \\    var xs = [1, 2]
        \\    free(xs[0:1])
        \\
    );
}

test "S7: a fresh object inside a loop dies every iteration" {
    try agreeClean(
        \\import std.strings
        \\
        \\func main():
        \\    for i in range(0, 1000):
        \\        var row = new Array(Int, 64)
        \\        row.fill(i)
        \\        var pieces = str(i).split(".")
        \\
    );
}

// ---------------------------------------------------------------------------
// B. Aliasing (S8-S10)
// ---------------------------------------------------------------------------

test "S8: let x = y is two names for one object, freed once" {
    try agreeClean(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    let view = xs
        \\    view.append(4)
        \\    assert(len(xs) == 4)
        \\    assert(view == xs)
        \\
    );
}

test "S8: an alias var cannot receive a fresh object" {
    try expectRejected(
        \\func main():
        \\    var xs = [1]
        \\    var view = xs
        \\    view = [9]
        \\
    );
}

test "S9: an alias after the owner freed traps at use" {
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2]
        \\    let view = xs
        \\    free(xs)
        \\    let bad = view[0]
        \\
    , .use_after_free);
}

test "S9: reusing the freed object's row does not revive its handle" {
    // The object table hands a freed row to the next `new`
    // (docs/MEMORY.md), so `fresh` occupies the row `xs` vacated.  S9
    // is a promise about the *object*, not about the row: the stale
    // alias traps here exactly as it does when nothing has moved in,
    // and never reads what `fresh` put there.
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2]
        \\    let view = xs
        \\    free(xs)
        \\    var fresh = [30, 40, 50]
        \\    assert(len(fresh) == 3)
        \\    assert(not (view == fresh))
        \\    let bad = view[0]
        \\
    , .use_after_free);
}

test "S10: give transfers between names and poisons the giver" {
    try agreeClean(
        \\func main():
        \\    var temp = [1, 2, 3]
        \\    let final_hits = give temp
        \\    assert(len(final_hits) == 3)
        \\
    );
    try expectRejected(
        \\func main():
        \\    var temp = [1, 2, 3]
        \\    let final_hits = give temp
        \\    let bad = temp[0]
        \\
    );
}

test "S10: give takes a name, not an expression" {
    try expectRejected(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    rows.append([1])
        \\    let bad = give rows[0]
        \\
    );
}

// ---------------------------------------------------------------------------
// C. Calls (S11-S15)
// ---------------------------------------------------------------------------

test "S11: passing an object is a borrow — free, silent, still owned by the caller" {
    try agreeClean(
        \\func total(values: List(Int)) -> Int:
        \\    var sum = 0
        \\    for v in values:
        \\        sum = sum + v
        \\    return sum
        \\
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    assert(total(xs) == 6)
        \\    assert(total(xs) == 6)
        \\    xs.append(4)
        \\
    );
}

test "S11: giving to a borrow parameter is a compile error" {
    try expectRejected(
        \\func peek(values: List(Int)) -> Int:
        \\    return len(values)
        \\
        \\func main():
        \\    var xs = [1]
        \\    let bad = peek(give xs)
        \\
    );
}

test "S12: a callee cannot keep a borrowed parameter" {
    // Storing into a container.
    try expectRejected(
        \\func stash(index: Map(String, List(Int)), hits: List(Int)):
        \\    index["latest"] = hits
        \\
        \\func main():
        \\    var index = new Map(String, List(Int))
        \\    var mine = [1]
        \\    stash(index, mine)
        \\
    );
    // Giving it away.
    try expectRejected(
        \\func keep(sink: List(List(Int)), hits: List(Int)):
        \\    sink.append(give hits)
        \\
        \\func main():
        \\    var sink = new List(List(Int))
        \\    var mine = [1]
        \\    keep(sink, mine)
        \\
    );
    // Freeing it.
    try expectRejected(
        \\func drop(hits: List(Int)):
        \\    free(hits)
        \\
        \\func main():
        \\    var mine = [1]
        \\    drop(mine)
        \\
    );
}

test "S13: give appears in the signature and at the call site" {
    try agreeClean(
        \\func stash(index: Map(String, List(Int)), hits: give List(Int)):
        \\    index["latest"] = give hits
        \\
        \\func main():
        \\    var index = new Map(String, List(Int))
        \\    var mine = [1, 2]
        \\    stash(index, give mine)
        \\    assert(len(index["latest"]) == 2)
        \\
    );
    // The caller must say it out loud: a bare name is refused.
    try expectRejected(
        \\func consume(xs: give List(Int)):
        \\    assert(len(xs) == 1)
        \\
        \\func main():
        \\    var mine = [1]
        \\    consume(mine)
        \\
    );
    // And the giver is poisoned afterwards.
    try expectRejected(
        \\func consume(xs: give List(Int)):
        \\    assert(len(xs) == 1)
        \\
        \\func main():
        \\    var mine = [1]
        \\    consume(give mine)
        \\    let bad = len(mine)
        \\
    );
}

test "S14: fresh values and copies satisfy a give parameter with no verb" {
    try agreeClean(
        \\func consume(xs: give List(Int)):
        \\    assert(len(xs) == 2)
        \\
        \\func main():
        \\    consume([7, 8])
        \\    var mine = [1, 2]
        \\    consume(copy mine)
        \\    assert(len(mine) == 2)
        \\
    );
}

test "S15: a give parameter not passed on dies with the callee" {
    try agreeClean(
        \\func consume(xs: give List(Int)):
        \\    xs.append(9)
        \\    assert(len(xs) == 3)
        \\
        \\func main():
        \\    var mine = [1, 2]
        \\    consume(give mine)
        \\
    );
}

// ---------------------------------------------------------------------------
// D. Returns (S16-S19)
// ---------------------------------------------------------------------------

test "S16: returning something you own moves it to the caller" {
    try agreeClean(
        \\func build() -> List(String):
        \\    var lines = ["a", "b"]
        \\    return lines
        \\
        \\func main():
        \\    var lines = build()
        \\    lines.append("c")
        \\    assert(len(lines) == 3)
        \\
    );
}

test "S17: returning a borrowed parameter is a compile error" {
    try expectRejected(
        \\func pick(xs: List(Int)) -> List(Int):
        \\    return xs
        \\
        \\func main():
        \\    var mine = [1]
        \\    var bad = pick(mine)
        \\
    );
    // An alias cannot be returned either.
    try expectRejected(
        \\func sneak() -> List(Int):
        \\    var xs = [1]
        \\    let view = xs
        \\    return view
        \\
        \\func main():
        \\    var bad = sneak()
        \\
    );
    // Nor a borrowed element; return a copy.
    try expectRejected(
        \\func first(rows: List(List(Int))) -> List(Int):
        \\    return rows[0]
        \\
        \\func main():
        \\    var rows = new List(List(Int))
        \\    rows.append([1])
        \\    var bad = first(rows)
        \\
    );
}

test "S17: return copy is the escape hatch for borrows" {
    try agreeClean(
        \\func first(rows: List(List(Int))) -> List(Int):
        \\    return copy rows[0]
        \\
        \\func main():
        \\    var rows = new List(List(Int))
        \\    rows.append([1, 2])
        \\    var taken = first(rows)
        \\    taken.append(3)
        \\    assert(len(rows[0]) == 2)
        \\    assert(len(taken) == 3)
        \\
    );
}

test "S18: returning a give parameter is legal — owned in, owned out" {
    try agreeClean(
        \\func sorted(values: give List(Float)) -> List(Float):
        \\    values.sort()
        \\    return values
        \\
        \\func main():
        \\    var ordered = sorted([3.0, 1.0, 2.0])
        \\    assert(ordered[0] == 1.0)
        \\
    );
}

test "S19: an ignored returned object is a temporary and frees itself" {
    try agreeClean(
        \\func build() -> List(String):
        \\    var lines = ["a", "b"]
        \\    return lines
        \\
        \\func main():
        \\    build()
        \\    build()
        \\
    );
}

// ---------------------------------------------------------------------------
// E. Containers (S20-S23)
// ---------------------------------------------------------------------------

test "S20: containers adopt fresh values silently and free them recursively" {
    try agreeClean(
        \\import std.strings
        \\
        \\func main():
        \\    var index = new Map(String, List(Int))
        \\    index["a.luc"] = [12, 40]
        \\    var words = new Map(String, List(String))
        \\    words["b.luc"] = "1 2 3".split(" ")
        \\    assert(len(words["b.luc"]) == 3)
        \\    var grid = new List(List(Int))
        \\    grid.append(new List(Int))
        \\    grid[0].append(5)
        \\    assert(grid[0][0] == 5)
        \\
    );
}

test "S20: freeing a container frees the objects it owns" {
    try agreeTrap(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    rows.append([1, 2])
        \\    let probe = rows[0]
        \\    free(rows)
        \\    let bad = probe[0]
        \\
    , .use_after_free);
}

test "S21: storing a bare name is a compile error at every container door" {
    // Map value.
    try expectRejected(
        \\func main():
        \\    var index = new Map(String, List(Int))
        \\    var hits = [12, 40]
        \\    index["a.luc"] = hits
        \\
    );
    // List append.
    try expectRejected(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    var hits = [1]
        \\    rows.append(hits)
        \\
    );
    // List insert.
    try expectRejected(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    var hits = [1]
        \\    rows.insert(0, hits)
        \\
    );
    // List element overwrite.
    try expectRejected(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    rows.append([0])
        \\    var hits = [1]
        \\    rows[0] = hits
        \\
    );
    // Array element.
    try expectRejected(
        \\func main():
        \\    var cells = new Array(List(Int), 2)
        \\    var hits = [1]
        \\    cells[0] = hits
        \\
    );
}

test "S21: give and copy open the container door" {
    try agreeClean(
        \\func main():
        \\    var index = new Map(String, List(Int))
        \\    var hits = [12, 40]
        \\    index["a.luc"] = give hits
        \\    var template = [0, 0]
        \\    index["b.luc"] = copy template
        \\    template.append(1)
        \\    assert(len(index["b.luc"]) == 2)
        \\    assert(len(template) == 3)
        \\
    );
}

test "S22: reading borrows; pop moves out; overwrite, remove, and clear free" {
    // pop hands the element to the receiver.
    try agreeClean(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    rows.append([1, 2])
        \\    let peek = rows[0]
        \\    assert(len(peek) == 2)
        \\    var taken = rows.pop()
        \\    assert(len(rows) == 0)
        \\    taken.append(3)
        \\    assert(len(taken) == 3)
        \\
    );
    // An element overwrite frees the old element right there.
    try agreeTrap(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    rows.append([9, 9])
        \\    let probe = rows[0]
        \\    rows[0] = [7]
        \\    let bad = probe[0]
        \\
    , .use_after_free);
    // remove frees the owned element.
    try agreeTrap(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    rows.append([9])
        \\    let probe = rows[0]
        \\    rows.remove(0)
        \\    let bad = probe[0]
        \\
    , .use_after_free);
    // clear frees all owned elements.
    try agreeTrap(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    rows.append([9])
        \\    let probe = rows[0]
        \\    rows.clear()
        \\    let bad = probe[0]
        \\
    , .use_after_free);
}

test "S22: map overwrite and remove free the old owned value" {
    try agreeClean(
        \\func main():
        \\    var index = new Map(String, List(Int))
        \\    index["a"] = [1]
        \\    index["a"] = [2, 3]
        \\    assert(len(index["a"]) == 2)
        \\    index.remove("a")
        \\    assert(len(index) == 0)
        \\
    );
}

test "S23: one object cannot end up owned twice — static poisoning" {
    try expectRejected(
        \\func main():
        \\    var a = new List(List(Int))
        \\    var b = new List(List(Int))
        \\    var item = [1]
        \\    a.append(give item)
        \\    b.append(give item)
        \\
    );
}

test "S23: the alias dodge is caught dynamically" {
    try agreeTrap(
        \\func main():
        \\    var a = new List(List(Int))
        \\    var b = new List(List(Int))
        \\    var item = [2]
        \\    let alias = item
        \\    a.append(give item)
        \\    b.append(give alias)
        \\
    , .not_owned);
}

// ---------------------------------------------------------------------------
// F. Structs (S24-S28)
// ---------------------------------------------------------------------------

test "S24: object fields follow the verb rule at construction" {
    try agreeClean(
        \\struct Bag:
        \\    label: String
        \\    items: List(Int)
        \\
        \\func main():
        \\    var bag = Bag(label = "a", items = [1, 2])
        \\    var loose = [3, 4]
        \\    var bag2 = Bag(label = "b", items = give loose)
        \\    var seed = [5]
        \\    var bag3 = Bag(label = "c", items = copy seed)
        \\    assert(len(bag.items) == 2)
        \\    assert(len(bag2.items) == 2)
        \\    assert(len(bag3.items) == 1)
        \\    seed.append(6)
        \\
    );
    try expectRejected(
        \\struct Bag:
        \\    label: String
        \\    items: List(Int)
        \\
        \\func main():
        \\    var loose = [3, 4]
        \\    var bag = Bag(label = "c", items = loose)
        \\
    );
}

test "S25: field assignment follows the verb rule and frees the old value" {
    // The old field object dies at the overwrite.
    try agreeTrap(
        \\struct Bag:
        \\    items: List(Int)
        \\
        \\func main():
        \\    var bag = Bag(items = [1])
        \\    let probe = bag.items
        \\    bag.items = [5, 6]
        \\    let bad = probe[0]
        \\
    , .use_after_free);
    // Bare names stay refused.
    try expectRejected(
        \\struct Bag:
        \\    items: List(Int)
        \\
        \\func main():
        \\    var bag = Bag(items = [1])
        \\    var loose = [2]
        \\    bag.items = loose
        \\
    );
    // Success path, no leaks.
    try agreeClean(
        \\struct Bag:
        \\    items: List(Int)
        \\
        \\func main():
        \\    var bag = Bag(items = [1])
        \\    bag.items = [5, 6]
        \\    var incoming = [7]
        \\    bag.items = give incoming
        \\    assert(len(bag.items) == 1)
        \\
    );
}

test "S25: only the owning name restocks an object field" {
    try expectRejected(
        \\struct Bag:
        \\    items: List(Int)
        \\
        \\func main():
        \\    var bag = Bag(items = [1])
        \\    var same = bag
        \\    same.items = [5]
        \\
    );
}

test "S26: struct copies alias the same objects" {
    try agreeClean(
        \\struct Bag:
        \\    label: String
        \\    items: List(Int)
        \\
        \\func main():
        \\    var bag = Bag(label = "a", items = [1, 2])
        \\    let same = bag
        \\    same.items.append(9)
        \\    assert(len(bag.items) == 3)
        \\
    );
}

test "S27: keeping an object-carrying struct needs a verb" {
    try expectRejected(
        \\struct Bag:
        \\    label: String
        \\    items: List(Int)
        \\
        \\func main():
        \\    var bags = new List(Bag)
        \\    var bag = Bag(label = "x", items = [1])
        \\    bags.append(bag)
        \\
    );
    try agreeClean(
        \\struct Bag:
        \\    label: String
        \\    items: List(Int)
        \\
        \\func main():
        \\    var bags = new List(Bag)
        \\    var bag = Bag(label = "x", items = [1])
        \\    bags.append(give bag)
        \\    bags.append(Bag(label = "y", items = [2]))
        \\    assert(len(bags) == 2)
        \\    assert(len(bags[0].items) == 1)
        \\
    );
}

test "S27: copy on a carrying struct deep-copies its owned objects" {
    try agreeClean(
        \\struct Bag:
        \\    label: String
        \\    items: List(Int)
        \\
        \\func main():
        \\    var bags = new List(Bag)
        \\    var bag = Bag(label = "x", items = [1])
        \\    bags.append(copy bag)
        \\    bag.items.append(2)
        \\    assert(len(bag.items) == 2)
        \\    assert(len(bags[0].items) == 1)
        \\
    );
}

test "S27: plain-value structs never need verbs" {
    try agreeClean(
        \\struct Point:
        \\    x: Int
        \\    y: Int
        \\
        \\func main():
        \\    var points = new List(Point)
        \\    var origin = Point(x = 0, y = 0)
        \\    points.append(origin)
        \\    points.append(Point(x = 1, y = 2))
        \\    assert(points[1].y == 2)
        \\
    );
}

test "S28: returning an object-carrying struct moves the whole tree" {
    try agreeClean(
        \\struct Bag:
        \\    label: String
        \\    items: List(Int)
        \\
        \\func make_bag() -> Bag:
        \\    var bag = Bag(label = "n", items = [1, 2])
        \\    return bag
        \\
        \\func main():
        \\    var mine = make_bag()
        \\    mine.items.append(3)
        \\    assert(len(mine.items) == 3)
        \\
    );
}

// ---------------------------------------------------------------------------
// G. give/copy mechanics (S29-S32)
// ---------------------------------------------------------------------------

test "S29: poisoning is source-order and branch-insensitive" {
    try expectRejected(
        \\func main():
        \\    var xs = [1]
        \\    var sink = new List(List(Int))
        \\    if len(sink) > 0:
        \\        sink.append(give xs)
        \\    let bad = len(xs)
        \\
    );
}

test "S29: a conditional give still releases correctly on both paths" {
    try agreeClean(
        \\func stash(flag: Bool) -> Int:
        \\    var xs = [1]
        \\    var sink = new List(List(Int))
        \\    if flag:
        \\        sink.append(give xs)
        \\    return len(sink)
        \\
        \\func main():
        \\    assert(stash(true) == 1)
        \\    assert(stash(false) == 0)
        \\
    );
}

test "S30: giving or freeing an outer name inside a loop is a compile error" {
    try expectRejected(
        \\func main():
        \\    var xs = [1]
        \\    var sink = new List(List(Int))
        \\    for i in range(0, 3):
        \\        sink.append(give xs)
        \\
    );
    try expectRejected(
        \\func main():
        \\    var xs = [1]
        \\    while true:
        \\        free(xs)
        \\
    );
}

test "S30: names created inside the loop give freely" {
    try agreeClean(
        \\func main():
        \\    var sink = new List(List(Int))
        \\    for i in range(0, 3):
        \\        var fresh = [i]
        \\        sink.append(give fresh)
        \\    assert(len(sink) == 3)
        \\
    );
}

test "S31: copy is deep and always legal on readable objects" {
    try agreeClean(
        \\func dup(borrowed: List(List(Int))) -> List(List(Int)):
        \\    return copy borrowed
        \\
        \\func main():
        \\    var nested = new List(List(Int))
        \\    nested.append([1, 2])
        \\    let mirror = copy nested
        \\    mirror[0].append(3)
        \\    assert(len(nested[0]) == 2)
        \\    assert(len(mirror[0]) == 3)
        \\    var again = dup(nested)
        \\    again[0].append(4)
        \\    assert(len(nested[0]) == 2)
        \\
    );
}

test "S31: slices of object lists are deep copies too" {
    try agreeClean(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    rows.append([1])
        \\    rows.append([2])
        \\    var front = rows[0:1]
        \\    front[0].append(9)
        \\    assert(len(rows[0]) == 1)
        \\    assert(len(front[0]) == 2)
        \\
    );
}

test "S32: values never take verbs" {
    try expectRejected(
        \\func main():
        \\    let name = "loom"
        \\    let title = give name
        \\
    );
    try expectRejected(
        \\func main():
        \\    let count = 3
        \\    let doubled = copy count
        \\
    );
    try expectRejected(
        \\func square(value: give Int) -> Int:
        \\    return value * value
        \\
        \\func main():
        \\    assert(square(3) == 9)
        \\
    );
}

// ---------------------------------------------------------------------------
// G2. Clarifications (S36-S39)
// ---------------------------------------------------------------------------

test "S36: ownership follows the binding, which lives where it was declared" {
    try agreeClean(
        \\func report(verbose: Bool) -> String:
        \\    var text = new Builder()
        \\    text.append("head")
        \\    if verbose:
        \\        text = new Builder()
        \\        text.append("details")
        \\    return str(text)
        \\
        \\func main():
        \\    assert(report(true) == "details")
        \\    assert(report(false) == "head")
        \\
    );
}

test "S37: values into containers need no ownership, ever" {
    try agreeClean(
        \\import std.strings
        \\
        \\func main():
        \\    var x: List(Int) = []
        \\    for i in range(0, 10):
        \\        x.append(i)
        \\    assert(len(x) == 10)
        \\    var names: List(String) = []
        \\    names.append("ada")
        \\    let alan = "alan"
        \\    names.append(alan)
        \\    assert(names.join(",") == "ada,alan")
        \\
    );
}

test "S38: a borrowed parameter may mutate contents" {
    try agreeClean(
        \\func fill_list(xs: List(Int)):
        \\    for i in range(0, 10):
        \\        xs.append(i)
        \\
        \\func main():
        \\    var x: List(Int) = []
        \\    fill_list(x)
        \\    assert(len(x) == 10)
        \\
    );
}

test "S39: let freezes the binding, not the object" {
    try agreeClean(
        \\func main():
        \\    let xs = [1, 2]
        \\    xs.append(3)
        \\    assert(len(xs) == 3)
        \\
    );
    // Re-pointing a let is still refused (luce.sema.let, not own).
    var result = try luce.compile.compile(testing.allocator,
        \\func main():
        \\    let xs = [1, 2]
        \\    xs = [9]
        \\
    , script);
    defer result.deinit();
    try testing.expect(result == .failure);
    try testing.expectEqualStrings("luce.sema.let", result.failure.at(0).?.code);
}

// ---------------------------------------------------------------------------
// H. Program edges (S33-S34) and mechanics the model relies on
// ---------------------------------------------------------------------------

test "S33: a busy program ends with zero live objects" {
    try agreeClean(
        \\struct Entry:
        \\    word: String
        \\    hits: List(Int)
        \\
        \\import std.strings
        \\
        \\func collect(text: String) -> List(Entry):
        \\    var entries = new List(Entry)
        \\    for word in text.split(" "):
        \\        entries.append(Entry(word = word, hits = [len(word)]))
        \\    return entries
        \\
        \\func main():
        \\    var entries = collect("a bb ccc")
        \\    assert(len(entries) == 3)
        \\    assert(entries[2].hits[0] == 3)
        \\
    );
}

test "S34: a trap mid-run aborts cleanly with objects in flight" {
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2]
        \\    var sink = new List(List(Int))
        \\    sink.append([3])
        \\    let bad = xs[9]
        \\
    , .index_bounds);
}

test "mechanics: a bare give with no receiver dies at the statement end" {
    try agreeClean(
        \\func main():
        \\    var xs = [1]
        \\    give xs
        \\
    );
}

test "mechanics: give checks the object exists — unfilled slots trap (S42)" {
    try agreeTrap(
        \\func main():
        \\    var inner: Builder
        \\    var sink = new List(Builder)
        \\    sink.append(give inner)
        \\
    , .null_object);
    try agreeTrap(
        \\func main():
        \\    var inner: List(Int)
        \\    let bad = copy inner
        \\
    , .null_object);
}

test "mechanics: deep recursion moves objects out without confusion" {
    try agreeClean(
        \\func chain(depth: Int) -> List(Int):
        \\    if depth == 0:
        \\        return [0]
        \\    var below = chain(depth - 1)
        \\    below.append(depth)
        \\    return below
        \\
        \\func main():
        \\    var xs = chain(100)
        \\    assert(len(xs) == 101)
        \\    assert(xs[100] == 100)
        \\
    );
}

test "mechanics: loop conditions that allocate flush every iteration" {
    try agreeClean(
        \\import std.strings
        \\
        \\func main():
        \\    var i = 0
        \\    while len(str(i).split(".")) > 0 and i < 100:
        \\        i = i + 1
        \\    assert(i == 100)
        \\
    );
}

test "mechanics: returning from inside a for over a fresh iterable frees it" {
    try agreeClean(
        \\import std.strings
        \\
        \\func hunt(text: String) -> String:
        \\    for word in text.split(" "):
        \\        if word.starts_with("b"):
        \\            return word
        \\    return ""
        \\
        \\func main():
        \\    assert(hunt("a bb c") == "bb")
        \\    assert(hunt("x y") == "")
        \\    for word in "p q".split(" "):
        \\        break
        \\
    );
}

test "mechanics: assignment can receive a give" {
    try agreeClean(
        \\func main():
        \\    var source = [1, 2]
        \\    var target: List(Int)
        \\    target = give source
        \\    target.append(3)
        \\    assert(len(target) == 3)
        \\
    );
}

test "mechanics: giving the same name twice in one statement is caught" {
    try expectRejected(
        \\func pair(a: give List(Int), b: give List(Int)):
        \\    assert(len(a) == len(b))
        \\
        \\func main():
        \\    var xs = [1]
        \\    pair(give xs, give xs)
        \\
    );
}

test "mechanics: short-circuit spills do not disturb ownership" {
    try agreeClean(
        \\func main():
        \\    var xs = [1]
        \\    var rows = new List(List(Int))
        \\    rows.append([len(xs), 2])
        \\    if len(xs) > 0 and len(rows[0]) > 1:
        \\        rows.append(xs[0:])
        \\    assert(len(rows) == 2)
        \\
    );
}

// ---------------------------------------------------------------------------
// G3. Late declarations and null (S40-S43)
// ---------------------------------------------------------------------------

test "S40: late declarations start at the type's zero value" {
    try agreeClean(
        \\struct Point:
        \\    x: Float
        \\    tag: String
        \\
        \\struct Nested:
        \\    label: String
        \\    at: Point
        \\    marks: List(Int)
        \\
        \\func main():
        \\    var count: Int
        \\    var ratio: Float
        \\    var open = true
        \\    var flag: Bool
        \\    var name: String
        \\    var spot: Nested
        \\    assert(count == 0)
        \\    assert(ratio == 0.0)
        \\    assert(open)
        \\    assert(not flag)
        \\    assert(name == "")
        \\    assert(spot.label == "")
        \\    assert(spot.at.x == 0.0)
        \\    assert(spot.at.tag == "")
        \\    count = 7
        \\    assert(count == 7)
        \\
    );
}

test "S40: the branch-set pattern works and the object outlives the if" {
    try agreeClean(
        \\func main():
        \\    var report: Builder
        \\    let verbose = true
        \\    if verbose:
        \\        report = new Builder()
        \\        report.append("details")
        \\    if verbose:
        \\        assert(str(report) == "details")
        \\    free(report)
        \\
    );
}

test "S41: using an unfilled object slot traps null_object" {
    const cases = [_][]const u8{
        \\func main():
        \\    var report: Builder
        \\    report.append("boom")
        \\
        ,
        \\func main():
        \\    var xs: List(Int)
        \\    let bad = xs[0]
        \\
        ,
        \\func main():
        \\    var xs: List(Int)
        \\    let bad = len(xs)
        \\
        ,
        \\func main():
        \\    var grid: Array(Int, _, _)
        \\    grid[0, 0] = 1
        \\
        ,
        \\func main():
        \\    var m: Map(String, Int)
        \\    for key in m:
        \\        let unused = key
        \\
    };
    for (cases) |source| {
        try agreeTrap(source, .null_object);
    }
}

test "S42: verbs demand an object — free of an unfilled slot traps" {
    try agreeTrap(
        \\func main():
        \\    var report: Builder
        \\    free(report)
        \\
    , .null_object);
}

test "S42: passing an unfilled slot traps at first use, not at the call" {
    try agreeTrap(
        \\func peek(xs: List(Int)) -> Int:
        \\    return 41 + 1
        \\
        \\func measure(xs: List(Int)) -> Int:
        \\    return len(xs)
        \\
        \\func main():
        \\    var xs: List(Int)
        \\    assert(peek(xs) == 42)
        \\    let bad = measure(xs)
        \\
    , .null_object);
}

test "S43: an unfilled slot frees nothing; a filled one frees normally" {
    try agreeClean(
        \\func main():
        \\    var never: Builder
        \\    var eventually: Builder
        \\    eventually = new Builder()
        \\    eventually.append("x")
        \\    free(eventually)
        \\
    );
}

// ---------------------------------------------------------------------------
// G4. Optionals change nothing (S1, S5, S16, S43; docs/FAILURE.md)
// ---------------------------------------------------------------------------
//
// `T?` is a type, not a second memory model.  Holding `none` owns
// nothing, holding an object owns exactly what the unwrapped type
// would, and every rule from S1 up reads the same on both.

test "optionals: a T? holding none owns nothing and releases nothing" {
    try agreeClean(
        \\func main():
        \\    var never: List(Int)? = none
        \\    var also: Builder? = none
        \\    also = none
        \\    var again: Map(String, Int)? = none
        \\    assert(never == none and also == none and again == none)
        \\
    );
}

test "optionals: a T? holding an object obeys scope ownership exactly as T does" {
    try agreeClean(
        \\func main():
        \\    var xs: List(Int)? = new List(Int)
        \\    xs.append(1)
        \\    assert(len(xs) == 1)
        \\
    );
    // Reassigning an owning slot frees the old object first (S5), and
    // `none` is a legal thing to reassign it to.
    try agreeClean(
        \\func main():
        \\    var xs: List(Int)? = new List(Int)
        \\    xs.append(1)
        \\    xs = new List(Int)
        \\    xs.append(2)
        \\    xs = none
        \\    assert(xs == none)
        \\
    );
    // And an explicit free still works through the narrowed name.
    try agreeClean(
        \\func main():
        \\    var xs: List(Int)? = none
        \\    xs = new List(Int)
        \\    free(xs)
        \\
    );
}

test "optionals: an object still moves out on return and into a give parameter" {
    try agreeClean(
        \\func make(wanted: Bool) -> List(Int)?:
        \\    if not wanted:
        \\        return none
        \\    var fresh = new List(Int)
        \\    fresh.append(3)
        \\    return fresh
        \\
        \\func consume(xs: give List(Int)):
        \\    free(xs)
        \\
        \\func main():
        \\    let nothing = make(false)
        \\    assert(nothing == none)
        \\    var something = make(true)
        \\    if something == none:
        \\        return
        \\    assert(len(something) == 1)
        \\    consume(give something)
        \\
    );
}

test "optionals: an object-carrying struct field may be absent and still frees" {
    try agreeClean(
        \\struct Bag:
        \\    label: String
        \\    items: List(Int)?
        \\
        \\func main():
        \\    var empty = Bag(label = "empty", items = none)
        \\    assert(empty.items == none)
        \\    var full = Bag(label = "full", items = new List(Int))
        \\    # A field is not a local, so it does not narrow (Dart's
        \\    # rule): bind it to a name and test that.
        \\    let held = full.items
        \\    if held != none:
        \\        held.append(1)
        \\        assert(len(held) == 1)
        \\    full.items = none
        \\    assert(full.items == none)
        \\
    );
}

test "optionals: the ownership rules still refuse what they refused" {
    // A binding that owns its object cannot be handed a borrow, `T?`
    // or not (S5, S21).
    try expectRejected(
        \\func main():
        \\    let source = new List(Int)
        \\    var kept: List(Int)? = none
        \\    kept = source
        \\
    );
    // A borrowed parameter cannot be given away (S12).
    try expectRejected(
        \\func steal(xs: List(Int)?) -> List(Int)?:
        \\    return xs
        \\
        \\func main():
        \\    let xs = new List(Int)
        \\    let taken = steal(xs)
        \\    free(xs)
        \\
    );
    // Poisoning survives the wrapper: a given name is untouchable.
    try expectRejected(
        \\func consume(xs: give List(Int)):
        \\    free(xs)
        \\
        \\func main():
        \\    var xs: List(Int)? = new List(Int)
        \\    consume(give xs)
        \\    assert(xs == none)
        \\
    );
}

test "optionals: use after free still traps through a T?" {
    try agreeTrap(
        \\func maybe() -> List(Int)?:
        \\    var fresh = new List(Int)
        \\    return fresh
        \\
        \\func main():
        \\    var xs = maybe()
        \\    let alias = xs
        \\    if xs != none:
        \\        free(xs)
        \\    if alias != none:
        \\        alias.append(1)
        \\
    , .use_after_free);
}

// ---------------------------------------------------------------------------
// Audit regressions: container doors the first release missed
// ---------------------------------------------------------------------------

test "audit: fill on arrays of objects is refused — one value cannot own every slot" {
    try expectRejected(
        \\func main():
        \\    var arr = new Array(List(Int), 2)
        \\    arr.fill([9])
        \\
    );
    try expectRejected(
        \\struct Bag:
        \\    items: List(Int)
        \\
        \\func main():
        \\    var arr = new Array(Bag, 2)
        \\    arr.fill(Bag(items = [1]))
        \\
    );
    // Value elements fill exactly as before.
    try agreeClean(
        \\func main():
        \\    var arr = new Array(Int, 4)
        \\    arr.fill(7)
        \\    assert(arr[3] == 7)
        \\    var cells = new Array(List(Int), 2)
        \\    cells[0] = [1]
        \\    cells[1] = [2]
        \\    assert(cells[1][0] == 2)
        \\
    );
}

test "audit: list literals are container doors too (S21)" {
    // A bare name in a literal is refused...
    try expectRejected(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var a = [xs]
        \\
    );
    // ...which keeps a borrowing callee from adopting the caller's
    // object (S11, S12).
    try expectRejected(
        \\func keepit(hits: List(Int)):
        \\    var wrapped = [hits]
        \\
        \\func main():
        \\    var xs = [1, 2]
        \\    keepit(xs)
        \\    assert(len(xs) == 2)
        \\
    );
    // Carrying structs need the verb here as well (S27).
    try expectRejected(
        \\struct Bag:
        \\    items: List(Int)
        \\
        \\func main():
        \\    var bag = Bag(items = [1])
        \\    var bags = [bag]
        \\
    );
    // give, copy, and fresh values open the door.
    try agreeClean(
        \\func main():
        \\    var xs = [1, 2]
        \\    var kept = [give xs]
        \\    var seed = [3]
        \\    var doubled = [copy seed, [4]]
        \\    seed.append(5)
        \\    assert(len(kept[0]) == 2)
        \\    assert(len(doubled[0]) == 1)
        \\    assert(len(seed) == 2)
        \\
    );
}

test "audit: the S30 guard sees while conditions" {
    try expectRejected(
        \\func eat(xs: give List(Int)) -> Int:
        \\    return len(xs)
        \\
        \\func main():
        \\    var xs = [1, 2]
        \\    var n = 0
        \\    while eat(give xs) > 0:
        \\        n = n + 1
        \\
    );
}

test "audit: give in a borrow position has no owner to receive it" {
    // Builtins borrow.
    try expectRejected(
        \\func main():
        \\    var xs = [1, 2]
        \\    let n = len(give xs)
        \\
    );
    // Non-adopting method arguments borrow.
    try expectRejected(
        \\func main():
        \\    var xs = new List(List(Int))
        \\    xs.append([1])
        \\    var ys = [1]
        \\    let same = xs.contains(give ys)
        \\
    );
    // Operators borrow.
    try expectRejected(
        \\func main():
        \\    var xs = [1]
        \\    var ys = [1]
        \\    let same = give xs == ys
        \\
    );
}

test "audit: a stale owner cannot free what an alias gave away" {
    try agreeTrap(
        \\func main():
        \\    var xs = [1, 2]
        \\    let a = xs
        \\    let s = give a
        \\    free(xs)
        \\
    , .not_owned);
}

test "audit: reassigning the iterated name mid-loop is a compile error" {
    try expectRejected(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    for x in xs:
        \\        xs = [9]
        \\
    );
    // The lock lifts when the loop ends.
    try agreeClean(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var total = 0
        \\    for x in xs:
        \\        total = total + x
        \\    xs = [9]
        \\    assert(total == 6)
        \\    assert(xs[0] == 9)
        \\
    );
}

test "audit: a routed String method hands its object to the caller (S16, S22)" {
    // `s.split(",")` is `strings.split(s, ",")` — a call, and a call's
    // result belongs to whoever receives it.  The classifier asks the
    // declaration's return type rather than a hand-kept list of method
    // names, so a new object-returning std function cannot arrive
    // without an owner: `expectClean` fails on a leak.
    try agreeClean(
        \\import std.strings
        \\
        \\func main():
        \\    let text = "a,b,c"
        \\    var parts = text.split(",")
        \\    assert(len(parts) == 3)
        \\    assert(parts[1] == "b")
        \\
    );
    // Unnamed, it is a statement temporary (S3, S19) and still dies.
    try agreeClean(
        \\import std.strings
        \\
        \\func main():
        \\    assert(len("a,b,c".split(",")) == 3)
        \\
    );
    // Kept in a container it is a store like any other (S20).
    try agreeClean(
        \\import std.strings
        \\
        \\func main():
        \\    var rows = new List(List(String))
        \\    rows.append("a,b".split(","))
        \\    assert(len(rows[0]) == 2)
        \\
    );
}

test "audit: give and free of an outer name are refused in every loop shape (S30)" {
    // The guard has to sit on the loop frame, not on the statement:
    // the second iteration is the one that would use the dead name.
    for ([_][]const u8{
        "    for i in range(0, 3):\n        sink.append(give xs)\n",
        "    for v in probe:\n        sink.append(give xs)\n",
        "    while len(probe) > 0:\n        sink.append(give xs)\n",
        "    for i in range(0, 3):\n        free(xs)\n",
        "    while len(probe) > 0:\n        free(xs)\n",
    }) |body| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(testing.allocator);
        try source.appendSlice(testing.allocator,
            \\func main():
            \\    var xs = [1]
            \\    var probe = [1]
            \\    var sink = new List(List(Int))
            \\
        );
        try source.appendSlice(testing.allocator, body);
        try expectRejected(source.items);
    }
}

// ---------------------------------------------------------------------------
// Value storage — docs/STRINGS.md
// ---------------------------------------------------------------------------
//
// A String's bytes and a struct's field run have exactly one owner, and
// the tests below are run under `std.testing.allocator`: what a program
// does not give back is a reported leak, and what it gives back twice
// is a reported double free.  That is the whole proof, so every one of
// these is really two assertions — the printed answer, and the
// allocator's silence.

test "storage: a returned view of a parameter comes out owned (S17 is an object rule)" {
    try agreeClean(
        \\import std.strings
        \\
        \\func widen(s: String) -> String:
        \\    return strings.trim(s)
        \\
        \\func unchanged(s: String) -> String:
        \\    return strings.replace(s, "", "!")
        \\
        \\func main():
        \\    let trimmed = widen("   padded   ")
        \\    let same = unchanged("kept")
        \\    assert(trimmed == "padded")
        \\    assert(same == "kept")
        \\
    );
}

test "storage: a container owns the bytes it is handed, and frees them with itself" {
    try agreeClean(
        \\func main():
        \\    var names = new List(String)
        \\    var seed = "ada"
        \\    names.append(seed)
        \\    names.append(seed + "-lovelace")
        \\    names.insert(0, "grace")
        \\    assert(names[1] == "ada")
        \\    names[1] = names[2]
        \\    assert(names[1] == "ada-lovelace")
        \\    names.remove(0)
        \\    assert(len(names) == 2)
        \\    var taken = names.pop()
        \\    assert(taken == "ada-lovelace")
        \\    free(names)
        \\
    );
}

test "storage: copy of a List(String) survives freeing the original (S31)" {
    try agreeClean(
        \\func main():
        \\    var first = new List(String)
        \\    first.append("alpha")
        \\    first.append("be" + "ta")
        \\    var second = copy first
        \\    free(first)
        \\    assert(second[0] == "alpha")
        \\    assert(second[1] == "beta")
        \\    var third = second[0:1]
        \\    free(second)
        \\    assert(third[0] == "alpha")
        \\    free(third)
        \\
    );
}

test "storage: a map owns its keys as well as its values" {
    try agreeClean(
        \\func main():
        \\    var table = new Map(String, String)
        \\    table["k" + str(1)] = "v1"
        \\    table["k1"] = "v" + str(2)
        \\    table["k2"] = "v2"
        \\    assert(table["k1"] == "v2")
        \\    assert(len(table) == 2)
        \\    var keys = table.keys()
        \\    var values = table.values()
        \\    assert(keys[0] == "k1")
        \\    assert(values[1] == "v2")
        \\    free(keys)
        \\    free(values)
        \\    table.remove("k1")
        \\    assert(len(table) == 1)
        \\    table.clear()
        \\    free(table)
        \\
    );
}

test "storage: a struct field assigned twice frees what it replaced (S25, S26)" {
    try agreeClean(
        \\struct Tag:
        \\    label: String
        \\    count: Int
        \\
        \\func main():
        \\    var tag = Tag(label = "one", count = 1)
        \\    tag.label = "two"
        \\    tag.label = tag.label + "-three"
        \\    assert(tag.label == "two-three")
        \\    var copied = tag
        \\    copied.label = "other"
        \\    assert(tag.label == "two-three")
        \\    assert(copied.label == "other")
        \\
    );
}

test "storage: reassignment reads the old bytes before releasing them (S5)" {
    try agreeClean(
        \\func main():
        \\    var text = "abcdef"
        \\    text = text[1:5]
        \\    text = text + text
        \\    assert(text == "bcdebcde")
        \\    var same = text
        \\    text = "gone"
        \\    assert(same == "bcdebcde")
        \\
    );
}

test "storage: an element read stays valid across a call that empties its container" {
    // The residual hazard docs/STRINGS.md closes statically: `pieces[0]`
    // is a view of an element the second argument frees.  An object
    // would go stale and trap (S9); a String has no handle, so the read
    // is copied instead.
    try agreeClean(
        \\func drop_first(pieces: List(String)) -> Int:
        \\    pieces.remove(0)
        \\    return 1
        \\
        \\func measure(left: String, right: Int) -> Int:
        \\    return len(left) + right
        \\
        \\func main():
        \\    var pieces = new List(String)
        \\    pieces.append("first-piece")
        \\    pieces.append("second")
        \\    assert(measure(pieces[0], drop_first(pieces)) == 12)
        \\    free(pieces)
        \\
    );
}

test "storage: a loop name that outlives a mutation of its collection keeps its own copy" {
    try agreeClean(
        \\func main():
        \\    var words = new List(String)
        \\    words.append("aa")
        \\    words.append("bb")
        \\    words.append("cc")
        \\    var seen = ""
        \\    for w in words:
        \\        seen = seen + w
        \\        words[0] = "zz"
        \\    assert(seen == "aabbcc")
        \\    var total = 0
        \\    for w in words:
        \\        total += len(w)
        \\    assert(total == 6)
        \\    free(words)
        \\
    );
}

test "storage: an Array of Strings and of structs owns every cell" {
    try agreeClean(
        \\struct Tag:
        \\    label: String
        \\    count: Int
        \\
        \\func main():
        \\    var cells = new Array(String, 3)
        \\    cells[0] = "x" + str(0)
        \\    cells[1] = cells[0]
        \\    cells[0] = "y"
        \\    assert(cells[0] == "y")
        \\    assert(cells[1] == "x0")
        \\    assert(len(cells[2]) == 0)
        \\    cells.fill("z")
        \\    assert(cells[1] == "z")
        \\    free(cells)
        \\    var marks = new Array(Tag, 2)
        \\    marks[0] = Tag(label = "m0", count = 0)
        \\    marks[1] = marks[0]
        \\    assert(marks[1].label == "m0")
        \\    free(marks)
        \\
    );
}

test "storage: a trap unwinds past every release and the bytes still come back" {
    // S34 keeps the object census honest by skipping releases on the
    // way out; value storage is not in the census, so the engine sweeps
    // the frames it left standing (docs/STRINGS.md).  Under
    // `std.testing.allocator` a missed sweep is a reported leak.
    try agreeTrap(
        \\struct Tag:
        \\    label: String
        \\    count: Int
        \\
        \\func deeper(name: String) -> Int:
        \\    let held = name + "-held"
        \\    var tag = Tag(label = held, count = 1)
        \\    trap(tag.label)
        \\
        \\func main():
        \\    let outer = "kept" + "-here"
        \\    var also = Tag(label = outer, count = 2)
        \\    assert(deeper(also.label) == 0)
        \\
    , .explicit_trap);
}

test "storage: a loop that retains nothing allocates nothing that outlives it" {
    try agreeClean(
        \\func main():
        \\    var total = 0
        \\    for i in range(0, 2000):
        \\        let piece = "item-" + str(i) + ";"
        \\        total += len(piece)
        \\    assert(total > 0)
        \\
    );
}
