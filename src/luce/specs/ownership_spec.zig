//! The executable specification of docs/OWNERSHIP.md.
//!
//! One test (or a small cluster) per ratified situation S1-S43,
//! numbered to match the document.  Each situation is proven three
//! ways where it applies: the behavior works, misuse is a compile
//! error with the stable code `luce.sema.own`, and the dynamic
//! backstops trap with stable codes.  Every successful run must end
//! with zero live objects — S33 says nothing can leak.

const std = @import("std");
const compile_mod = @import("../compile.zig");
const types = @import("../support/types.zig");
const mir = @import("../06_mir.zig");
const backend = @import("../backend.zig");

const testing = std.testing;

const script: types.CompileOptions = .{ .entry_mode = .script };

const Outcome = union(enum) {
    /// Objects still alive after a successful run — always expected 0.
    leaked: u32,
    trap: mir.TrapCode,
};

fn run(source: []const u8) !Outcome {
    var result = try compile_mod.compile(testing.allocator, source, .{}, script);
    defer result.deinit();
    switch (result) {
        .failure => |*diagnostics| {
            const rendered = try diagnostics.render(testing.allocator);
            defer testing.allocator.free(rendered);
            std.debug.print("unexpected diagnostics:\n{s}", .{rendered});
            return error.TestUnexpectedResult;
        },
        .success => |*program| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const outcome = try backend.evaluate(.{ .arena = arena.allocator(), .objects = testing.allocator }, program, &.{}, &.{}, .{
                .steps = 5_000_000,
                .call_depth = 256,
            });
            return switch (outcome) {
                .success => |success| .{ .leaked = success.leaked_objects },
                .trap => |trap| .{ .trap = trap.code },
                .unavailable => error.TestUnexpectedResult,
            };
        },
    }
}

/// The program runs, its assertions hold, and nothing leaks (S33).
fn expectClean(source: []const u8) !void {
    const outcome = try run(source);
    if (outcome == .trap) {
        std.debug.print("unexpected trap: {s}\n", .{@tagName(outcome.trap)});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(u32, 0), outcome.leaked);
}

fn expectTrap(source: []const u8, code: mir.TrapCode) !void {
    const outcome = try run(source);
    if (outcome != .trap) {
        std.debug.print("expected trap {s}, but the program finished\n", .{@tagName(code)});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(code, outcome.trap);
}

/// The program is rejected with the stable ownership code.
fn expectOwnError(source: []const u8) !void {
    var result = try compile_mod.compile(testing.allocator, source, .{}, script);
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
    try expectClean(
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
    try expectTrap(
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
    try expectClean(
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
    try expectClean(
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
    try expectClean(
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
    try expectTrap(
        \\func main():
        \\    var xs = [1]
        \\    let view = xs
        \\    xs = [2, 3]
        \\    let bad = view[0]
        \\
    , .use_after_free);
}

test "S5: the life.luc pattern — reassign in a loop, no free dance" {
    try expectClean(
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
    try expectOwnError(
        \\func main():
        \\    var xs = [1]
        \\    var ys = [2]
        \\    xs = ys
        \\
    );
}

test "S6: free is early release and poisons the name" {
    try expectClean(
        \\import std.strings
        \\
        \\func main():
        \\    var big = "a b c d".split(" ")
        \\    let count = len(big)
        \\    free(big)
        \\    assert(count == 4)
        \\
    );
    try expectOwnError(
        \\func main():
        \\    var big = [1, 2]
        \\    free(big)
        \\    let bad = big[0]
        \\
    );
}

test "S6: free applies to owned names only" {
    // An alias cannot free.
    try expectOwnError(
        \\func main():
        \\    var xs = [1]
        \\    let view = xs
        \\    free(view)
        \\
    );
    // Neither can an arbitrary expression.
    try expectOwnError(
        \\func main():
        \\    var xs = [1, 2]
        \\    free(xs[0:1])
        \\
    );
}

test "S7: a fresh object inside a loop dies every iteration" {
    try expectClean(
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
    try expectClean(
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
    try expectOwnError(
        \\func main():
        \\    var xs = [1]
        \\    var view = xs
        \\    view = [9]
        \\
    );
}

test "S9: an alias after the owner freed traps at use" {
    try expectTrap(
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
    try expectTrap(
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
    try expectClean(
        \\func main():
        \\    var temp = [1, 2, 3]
        \\    let final_hits = give temp
        \\    assert(len(final_hits) == 3)
        \\
    );
    try expectOwnError(
        \\func main():
        \\    var temp = [1, 2, 3]
        \\    let final_hits = give temp
        \\    let bad = temp[0]
        \\
    );
}

test "S10: give takes a name, not an expression" {
    try expectOwnError(
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
    try expectClean(
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
    try expectOwnError(
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
    try expectOwnError(
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
    try expectOwnError(
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
    try expectOwnError(
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
    try expectClean(
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
    try expectOwnError(
        \\func consume(xs: give List(Int)):
        \\    assert(len(xs) == 1)
        \\
        \\func main():
        \\    var mine = [1]
        \\    consume(mine)
        \\
    );
    // And the giver is poisoned afterwards.
    try expectOwnError(
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
    try expectClean(
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
    try expectClean(
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
    try expectClean(
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
    try expectOwnError(
        \\func pick(xs: List(Int)) -> List(Int):
        \\    return xs
        \\
        \\func main():
        \\    var mine = [1]
        \\    var bad = pick(mine)
        \\
    );
    // An alias cannot be returned either.
    try expectOwnError(
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
    try expectOwnError(
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
    try expectClean(
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
    try expectClean(
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
    try expectClean(
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
    try expectClean(
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
    try expectTrap(
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
    try expectOwnError(
        \\func main():
        \\    var index = new Map(String, List(Int))
        \\    var hits = [12, 40]
        \\    index["a.luc"] = hits
        \\
    );
    // List append.
    try expectOwnError(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    var hits = [1]
        \\    rows.append(hits)
        \\
    );
    // List insert.
    try expectOwnError(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    var hits = [1]
        \\    rows.insert(0, hits)
        \\
    );
    // List element overwrite.
    try expectOwnError(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    rows.append([0])
        \\    var hits = [1]
        \\    rows[0] = hits
        \\
    );
    // Array element.
    try expectOwnError(
        \\func main():
        \\    var cells = new Array(List(Int), 2)
        \\    var hits = [1]
        \\    cells[0] = hits
        \\
    );
}

test "S21: give and copy open the container door" {
    try expectClean(
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
    try expectClean(
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
    try expectTrap(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    rows.append([9, 9])
        \\    let probe = rows[0]
        \\    rows[0] = [7]
        \\    let bad = probe[0]
        \\
    , .use_after_free);
    // remove frees the owned element.
    try expectTrap(
        \\func main():
        \\    var rows = new List(List(Int))
        \\    rows.append([9])
        \\    let probe = rows[0]
        \\    rows.remove(0)
        \\    let bad = probe[0]
        \\
    , .use_after_free);
    // clear frees all owned elements.
    try expectTrap(
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
    try expectClean(
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
    try expectOwnError(
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
    try expectTrap(
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
    try expectClean(
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
    try expectOwnError(
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
    try expectTrap(
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
    try expectOwnError(
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
    try expectClean(
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
    try expectOwnError(
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
    try expectClean(
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
    try expectOwnError(
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
    try expectClean(
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
    try expectClean(
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
    try expectClean(
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
    try expectClean(
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
    try expectOwnError(
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
    try expectClean(
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
    try expectOwnError(
        \\func main():
        \\    var xs = [1]
        \\    var sink = new List(List(Int))
        \\    for i in range(0, 3):
        \\        sink.append(give xs)
        \\
    );
    try expectOwnError(
        \\func main():
        \\    var xs = [1]
        \\    while true:
        \\        free(xs)
        \\
    );
}

test "S30: names created inside the loop give freely" {
    try expectClean(
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
    try expectClean(
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
    try expectClean(
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
    try expectOwnError(
        \\func main():
        \\    let name = "loom"
        \\    let title = give name
        \\
    );
    try expectOwnError(
        \\func main():
        \\    let count = 3
        \\    let doubled = copy count
        \\
    );
    try expectOwnError(
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
    try expectClean(
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
    try expectClean(
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
    try expectClean(
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
    try expectClean(
        \\func main():
        \\    let xs = [1, 2]
        \\    xs.append(3)
        \\    assert(len(xs) == 3)
        \\
    );
    // Re-pointing a let is still refused (luce.sema.let, not own).
    var result = try compile_mod.compile(testing.allocator,
        \\func main():
        \\    let xs = [1, 2]
        \\    xs = [9]
        \\
    , .{}, script);
    defer result.deinit();
    try testing.expect(result == .failure);
    try testing.expectEqualStrings("luce.sema.let", result.failure.at(0).?.code);
}

// ---------------------------------------------------------------------------
// H. Program edges (S33-S34) and mechanics the model relies on
// ---------------------------------------------------------------------------

test "S33: a busy program ends with zero live objects" {
    try expectClean(
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
    try expectTrap(
        \\func main():
        \\    var xs = [1, 2]
        \\    var sink = new List(List(Int))
        \\    sink.append([3])
        \\    let bad = xs[9]
        \\
    , .index_bounds);
}

test "mechanics: a bare give with no receiver dies at the statement end" {
    try expectClean(
        \\func main():
        \\    var xs = [1]
        \\    give xs
        \\
    );
}

test "mechanics: give checks the object exists — unfilled slots trap (S42)" {
    try expectTrap(
        \\func main():
        \\    var inner: Builder
        \\    var sink = new List(Builder)
        \\    sink.append(give inner)
        \\
    , .null_object);
    try expectTrap(
        \\func main():
        \\    var inner: List(Int)
        \\    let bad = copy inner
        \\
    , .null_object);
}

test "mechanics: deep recursion moves objects out without confusion" {
    try expectClean(
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
    try expectClean(
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
    try expectClean(
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
    try expectClean(
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
    try expectOwnError(
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
    try expectClean(
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
    try expectClean(
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
    try expectClean(
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
        try expectTrap(source, .null_object);
    }
}

test "S42: verbs demand an object — free of an unfilled slot traps" {
    try expectTrap(
        \\func main():
        \\    var report: Builder
        \\    free(report)
        \\
    , .null_object);
}

test "S42: passing an unfilled slot traps at first use, not at the call" {
    try expectTrap(
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
    try expectClean(
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
    try expectClean(
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
    try expectClean(
        \\func main():
        \\    var xs: List(Int)? = new List(Int)
        \\    xs.append(1)
        \\    assert(len(xs) == 1)
        \\
    );
    // Reassigning an owning slot frees the old object first (S5), and
    // `none` is a legal thing to reassign it to.
    try expectClean(
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
    try expectClean(
        \\func main():
        \\    var xs: List(Int)? = none
        \\    xs = new List(Int)
        \\    free(xs)
        \\
    );
}

test "optionals: an object still moves out on return and into a give parameter" {
    try expectClean(
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
    try expectClean(
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
    try expectOwnError(
        \\func main():
        \\    let source = new List(Int)
        \\    var kept: List(Int)? = none
        \\    kept = source
        \\
    );
    // A borrowed parameter cannot be given away (S12).
    try expectOwnError(
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
    try expectOwnError(
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
    try expectTrap(
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
    try expectOwnError(
        \\func main():
        \\    var arr = new Array(List(Int), 2)
        \\    arr.fill([9])
        \\
    );
    try expectOwnError(
        \\struct Bag:
        \\    items: List(Int)
        \\
        \\func main():
        \\    var arr = new Array(Bag, 2)
        \\    arr.fill(Bag(items = [1]))
        \\
    );
    // Value elements fill exactly as before.
    try expectClean(
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
    try expectOwnError(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    var a = [xs]
        \\
    );
    // ...which keeps a borrowing callee from adopting the caller's
    // object (S11, S12).
    try expectOwnError(
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
    try expectOwnError(
        \\struct Bag:
        \\    items: List(Int)
        \\
        \\func main():
        \\    var bag = Bag(items = [1])
        \\    var bags = [bag]
        \\
    );
    // give, copy, and fresh values open the door.
    try expectClean(
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
    try expectOwnError(
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
    try expectOwnError(
        \\func main():
        \\    var xs = [1, 2]
        \\    let n = len(give xs)
        \\
    );
    // Non-adopting method arguments borrow.
    try expectOwnError(
        \\func main():
        \\    var xs = new List(List(Int))
        \\    xs.append([1])
        \\    var ys = [1]
        \\    let same = xs.contains(give ys)
        \\
    );
    // Operators borrow.
    try expectOwnError(
        \\func main():
        \\    var xs = [1]
        \\    var ys = [1]
        \\    let same = give xs == ys
        \\
    );
}

test "audit: a stale owner cannot free what an alias gave away" {
    try expectTrap(
        \\func main():
        \\    var xs = [1, 2]
        \\    let a = xs
        \\    let s = give a
        \\    free(xs)
        \\
    , .not_owned);
}

test "audit: reassigning the iterated name mid-loop is a compile error" {
    try expectOwnError(
        \\func main():
        \\    var xs = [1, 2, 3]
        \\    for x in xs:
        \\        xs = [9]
        \\
    );
    // The lock lifts when the loop ends.
    try expectClean(
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
    try expectClean(
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
    try expectClean(
        \\import std.strings
        \\
        \\func main():
        \\    assert(len("a,b,c".split(",")) == 3)
        \\
    );
    // Kept in a container it is a store like any other (S20).
    try expectClean(
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
        try expectOwnError(source.items);
    }
}
