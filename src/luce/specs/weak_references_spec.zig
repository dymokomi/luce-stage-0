//! Zeroing weak references, exercised through both execution engines.
//!
//! Weakness belongs to a storage place, not to a value type. A read upgrades
//! one live target to an owned optional snapshot; a dead target reads `none`.
//! These programs keep the lifetime edges visible so either an accidental
//! retain or a missing retain becomes an output or leak disagreement.

const agree = @import("agree.zig");
const testing = @import("std").testing;

test "a weak local observes one lifetime and never revives on row reuse" {
    try agree.ok(
        \\func main():
        \\    weak var observed: list[i64]?
        \\    assert(observed == none)
        \\    if true:
        \\        let first = [41]
        \\        observed = first
        \\        let live = observed else [0]
        \\        assert(live[0] == 41)
        \\    assert(observed == none)
        \\    let second = [42]
        \\    assert(second[0] == 42)
        \\    assert(observed == none)
        \\
    );
}

test "an upgraded weak snapshot keeps its target alive until that snapshot dies" {
    try agree.ok(
        \\func main():
        \\    weak var observed: list[i64]? = none
        \\    var kept: list[i64]? = none
        \\    if true:
        \\        let source = [42]
        \\        observed = source
        \\        kept = observed
        \\    assert(observed != none)
        \\    if true:
        \\        let snapshot = observed else [0]
        \\        assert(snapshot[0] == 42)
        \\    kept = none
        \\    assert(observed == none)
        \\
    );
}

test "weak fields initialize, assign through a nested value place, and zero" {
    try agree.ok(
        \\struct Observer:
        \\    weak target: list[i64]?
        \\
        \\struct Pair:
        \\    observer: Observer
        \\    marker: i64
        \\
        \\func main():
        \\    var pair = Pair(observer = Observer(), marker = 7)
        \\    assert(pair.observer.target == none)
        \\    if true:
        \\        let source = [35]
        \\        pair.observer.target = source
        \\        let snapshot = pair.observer.target else [0]
        \\        assert(snapshot[0] + pair.marker == 42)
        \\    assert(pair.observer.target == none)
        \\
    );
}

test "a weak field breaks a recursive struct and container cycle" {
    try agree.ok(
        \\struct Link:
        \\    weak root: list[Link]?
        \\
        \\func main():
        \\    let root: list[Link] = [Link()]
        \\    root[0].root = root
        \\    let snapshot = root[0].root else [Link()]
        \\    assert(len(snapshot) == 1)
        \\
    );
}

test "every ARC object family can be observed weakly" {
    try agree.ok(
        \\func main():
        \\    weak var listed: list[i64]? = none
        \\    weak var mapped: map[str, i64]? = none
        \\    weak var arrayed: array[i64, _]? = none
        \\    weak var built: builder? = none
        \\    if true:
        \\        let xs = [1]
        \\        let table = new map[str, i64]
        \\        let cells = new array[i64](1)
        \\        let text = new builder
        \\        listed = xs
        \\        mapped = table
        \\        arrayed = cells
        \\        built = text
        \\        assert(listed != none and mapped != none)
        \\        assert(arrayed != none and built != none)
        \\    assert(listed == none and mapped == none)
        \\    assert(arrayed == none and built == none)
        \\
    );
}

test "zero templates and semantic copies preserve weak storage" {
    try agree.ok(
        \\struct Observer:
        \\    weak target: list[i64]?
        \\
        \\func main():
        \\    var zeroed: Observer
        \\    assert(zeroed.target == none)
        \\    var original = Observer()
        \\    if true:
        \\        let source = [42]
        \\        original.target = source
        \\        let copied = original
        \\        assert(copied.target != none)
        \\    assert(original.target == none)
        \\
    );
}

test "assigning none clears weak storage without touching the target" {
    try agree.ok(
        \\func main():
        \\    let source = [42]
        \\    weak var observed: list[i64]? = source
        \\    assert(observed != none)
        \\    observed = none
        \\    assert(observed == none)
        \\    assert(source[0] == 42)
        \\
    );
}

test "an alias may name the optional type of weak storage" {
    try agree.ok(
        \\alias MaybeRows = list[i64]?
        \\
        \\func main():
        \\    weak var observed: MaybeRows
        \\    assert(observed == none)
        \\    if true:
        \\        let rows = [42]
        \\        observed = rows
        \\        assert((observed else [0])[0] == 42)
        \\    assert(observed == none)
        \\
    );
}

test "a reference stored only weakly dies at the statement boundary" {
    try agree.ok(
        \\struct Observer:
        \\    weak target: list[i64]?
        \\
        \\func main():
        \\    weak var local: list[i64]? = [41]
        \\    assert(local == none)
        \\    let field = Observer(target = [42])
        \\    assert(field.target == none)
        \\
    );
}

test "repeated weak upgrades release every owned snapshot" {
    try agree.ok(
        \\func main():
        \\    let source = [42]
        \\    weak var observed: list[i64]? = source
        \\    var total = 0
        \\    for i in range(0, 1000):
        \\        let snapshot = observed else [0]
        \\        total = total + snapshot[0]
        \\    assert(total == 42000)
        \\
    );
}

test "a weak files.File observes the descriptor's lifetime without extending it" {
    // A File is an ordinary class, so weak storage works on it the
    // way it works on any class — the Swift shape, where a weak
    // NWConnection is bookkeeping and never keeps a socket open.
    // The upgrade holds the file alive for the read; releasing the
    // strong reference closes the descriptor and zeroes the observer.
    const world: agree.World = .withFile("notes.txt", "abcdef");
    var session = try agree.compare(
        \\import std.files
        \\
        \\func main() -> !:
        \\    weak var observed: files.File?
        \\    if true:
        \\        var f = try files.open("notes.txt")
        \\        observed = f
        \\        let live = observed
        \\        if live == none:
        \\            print("dead")
        \\            return
        \\        var buffer = new array[u8](6)
        \\        print(str(try live.read(buffer)))
        \\    if observed == none:
        \\        print("closed")
        \\
    , .{ .world = world });
    defer session.deinit();

    try testing.expectEqualStrings("6\nclosed\n", session.printed());
    try testing.expectEqual(agree.End{ .finished = 0 }, session.end);
}
