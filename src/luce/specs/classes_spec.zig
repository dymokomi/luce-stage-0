//! Final ARC classes, exercised through both execution engines.
//!
//! A class binding holds one reference to an identity-bearing object. Copies
//! retain that object, fields mutate through stable `let` bindings, and every
//! ordinary storage form keeps the same identity rather than copying fields.

const agree = @import("agree.zig");

test "class aliases observe shared field mutation through let bindings" {
    try agree.ok(
        \\class Counter:
        \\    count: i64
        \\
        \\func main():
        \\    let first = Counter(count = 1)
        \\    let second = first
        \\    second.count = second.count + 41
        \\    assert(first.count == 42)
        \\
    );
}

test "class identity uses is while equal field values stay distinct" {
    try agree.ok(
        \\class Token:
        \\    value: i64
        \\
        \\func main():
        \\    let first = Token(value = 7)
        \\    let same = first
        \\    let separate = Token(value = 7)
        \\    assert(first is same)
        \\    assert(not (first is separate))
        \\
    );
}

test "class methods mutate shared self and expose multiple methods" {
    try agree.ok(
        \\class Counter:
        \\    count: i64
        \\    func add(amount: i64) -> i64:
        \\        self.count += amount
        \\        return self.count
        \\    func current() -> i64:
        \\        return self.count
        \\
        \\func main():
        \\    let counter = Counter(count = 1)
        \\    let same = counter
        \\    assert(same.add(amount = 40) == 41)
        \\    assert(counter.add(1) == 42)
        \\    assert(same.current() == 42)
        \\
    );
}

test "nested value fields rebuild until the nearest class identity" {
    try agree.ok(
        \\struct Point:
        \\    x: i64
        \\    y: i64
        \\
        \\class Scene:
        \\    point: Point
        \\
        \\struct Holder:
        \\    scene: Scene
        \\
        \\func main():
        \\    let scene = Scene(point = Point(x = 1, y = 2))
        \\    let holder = Holder(scene = scene)
        \\    holder.scene.point.x = 40
        \\    scene.point.y += 2
        \\    assert(holder.scene.point.x + scene.point.y == 44)
        \\
    );
}

test "a class witness keeps identity through interfaces lists and maps" {
    try agree.ok(
        \\interface Incrementing:
        \\    func add(amount: i64) -> i64
        \\
        \\class Counter: Incrementing:
        \\    count: i64
        \\    func add(amount: i64) -> i64:
        \\        self.count += amount
        \\        return self.count
        \\
        \\func apply(item: Incrementing, amount: i64) -> i64:
        \\    return item.add(amount)
        \\
        \\func main():
        \\    let counter = Counter(count = 1)
        \\    var items = new list[Incrementing]
        \\    items.append(counter)
        \\    var table = new map[str, Incrementing]
        \\    table["counter"] = counter
        \\    assert(apply(items[0], 20) == 21)
        \\    assert(apply(table["counter"], 21) == 42)
        \\    assert(counter.count == 42)
        \\
    );
}

test "class references retain identity through parameters returns optionals lists and maps" {
    try agree.ok(
        \\class Box:
        \\    value: i64
        \\
        \\func pass(box: Box) -> Box:
        \\    return box
        \\
        \\func update(box: Box):
        \\    box.value = 42
        \\
        \\func maybe(box: Box, keep: bool) -> Box?:
        \\    if keep:
        \\        return box
        \\    return none
        \\
        \\func main():
        \\    let original = Box(value = 1)
        \\    let returned = pass(original)
        \\    let optional = maybe(returned, true)
        \\    let present = optional else Box(value = 0)
        \\    let items: list[Box] = [present]
        \\    let table: map[str, Box] = {"box": items[0]}
        \\    update(table["box"])
        \\    assert(original.value == 42)
        \\
    );
}

test "a weak class back edge zeros after the last strong reference" {
    try agree.ok(
        \\class Node:
        \\    value: i64
        \\    weak parent: Node?
        \\
        \\func main():
        \\    weak var observed: Node?
        \\    if true:
        \\        let parent = Node(value = 41)
        \\        let child = Node(value = 1, parent = parent)
        \\        observed = parent
        \\        let live = child.parent else child
        \\        assert(live.value + child.value == 42)
        \\    assert(observed == none)
        \\
    );
}

test "deinit runs exactly once at the last alias and sees live fields" {
    try agree.prints(
        \\class Resource:
        \\    value: i64
        \\    func prepare():
        \\        self.value += 1
        \\    deinit:
        \\        self.prepare()
        \\        print("closed " + str(self.value))
        \\
        \\func main():
        \\    if true:
        \\        let first = Resource(value = 41)
        \\        let second = first
        \\        assert(first is second)
        \\    print("after")
        \\
    , "closed 42\nafter\n");
}

test "deinit runs before releasing class-owned child fields" {
    try agree.prints(
        \\class Child:
        \\    name: str
        \\    deinit:
        \\        print("child " + self.name)
        \\
        \\class Parent:
        \\    name: str
        \\    child: Child
        \\    deinit:
        \\        print("parent " + self.name + " owns " + self.child.name)
        \\
        \\func main():
        \\    if true:
        \\        let parent = Parent(name = "one", child = Child(name = "two"))
        \\        assert(parent.child.name == "two")
        \\
    , "parent one owns two\nchild two\n");
}

test "optionals interfaces lists and maps preserve one class lifetime" {
    try agree.prints(
        \\interface Named:
        \\    func name() -> str
        \\
        \\class Item: Named:
        \\    label: str
        \\    func name() -> str:
        \\        return self.label
        \\    deinit:
        \\        print("closed " + self.label)
        \\
        \\func optional(item: Item, keep: bool) -> Item?:
        \\    if keep:
        \\        return item
        \\    return none
        \\
        \\func main():
        \\    if true:
        \\        let item = Item(label = "shared")
        \\        let maybe = optional(item, true)
        \\        let named: Named = item
        \\        let items: list[Item] = [item]
        \\        let table: map[str, Item] = {"one": item}
        \\        let present = maybe else item
        \\        assert(present is item)
        \\        assert(named.name() == items[0].label)
        \\        assert(table["one"] is item)
        \\        print("leaving")
        \\    print("left")
        \\
    , "leaving\nclosed shared\nleft\n");
}

test "weak self is permitted during deinit but cannot upgrade" {
    try agree.prints(
        \\class Node:
        \\    weak observed: Node?
        \\    deinit:
        \\        self.observed = self
        \\        assert(self.observed == none)
        \\        weak var local: Node? = self
        \\        assert(local == none)
        \\        print("zero")
        \\
        \\func main():
        \\    if true:
        \\        let node = Node()
        \\
    , "zero\n");
}

test "recoverable error unwinding runs deinit before the handler" {
    try agree.prints(
        \\class Resource:
        \\    name: str
        \\    deinit:
        \\        print("closed " + self.name)
        \\
        \\func fail() -> !:
        \\    let resource = Resource(name = "error path")
        \\    assert(resource.name == "error path")
        \\    error("stopped")
        \\
        \\func main():
        \\    fail() catch reason:
        \\        print("caught " + reason)
        \\
    , "closed error path\ncaught stopped\n");
}

test "a deinit trap stops the releasing operation and preserves its trace" {
    try agree.trapSays(
        \\class Resource:
        \\    name: str
        \\    deinit:
        \\        trap("failed to close " + self.name)
        \\
        \\func main():
        \\    if true:
        \\        let resource = Resource(name = "socket")
        \\
    , .explicit_trap, "failed to close socket");
}

test "worker-local classes use the worker runtime's finalizer channel" {
    try agree.prints(
        \\class Resource:
        \\    name: str
        \\    deinit:
        \\        print("worker closed " + self.name)
        \\
        \\func work() -> i64:
        \\    if true:
        \\        let resource = Resource(name = "local")
        \\        assert(resource.name == "local")
        \\    return 42
        \\
        \\func main():
        \\    let task = spawn work()
        \\    assert(task.wait() == 42)
        \\
    , "worker closed local\n");
}
