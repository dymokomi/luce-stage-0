//! Final ARC classes, exercised through both execution engines.
//!
//! A class binding holds one reference to an identity-bearing object. Copies
//! retain that object, fields mutate through stable `let` bindings, and every
//! ordinary storage form keeps the same identity rather than copying fields.

const agree = @import("agree.zig");

test "custom init computes several fields and keeps defaults and call defaults" {
    try agree.ok(
        \\class Rectangle:
        \\    label: str = "rectangle"
        \\    width: i64
        \\    height: i64
        \\    area: i64
        \\    init(width: i64, height: i64 = 2):
        \\        self.width = width
        \\        self.height = height
        \\        self.area = self.width * self.height
        \\
        \\func main():
        \\    let first = Rectangle(6)
        \\    let second = Rectangle(height = 7, width = 3)
        \\    assert(first.label == "rectangle")
        \\    assert(first.area == 12)
        \\    assert(second.area == 21)
        \\
    );
}

test "custom init joins branches and permits a complete early return" {
    try agree.ok(
        \\class Number:
        \\    value: i64
        \\    sign: str
        \\    init(value: i64):
        \\        if value == 0:
        \\            self.value = 0
        \\            self.sign = "zero"
        \\            return
        \\        if value > 0:
        \\            self.sign = "positive"
        \\        else:
        \\            self.sign = "negative"
        \\        self.value = value
        \\
        \\func main():
        \\    let zero = Number(0)
        \\    let negative = Number(-4)
        \\    assert(zero.value == 0 and zero.sign == "zero")
        \\    assert(negative.value == -4 and negative.sign == "negative")
        \\
    );
}

test "custom init supports nested updates after the root field exists" {
    try agree.ok(
        \\struct Point:
        \\    x: i64
        \\    y: i64
        \\
        \\class Scene:
        \\    point: Point
        \\    values: list[i64]
        \\    init(x: i64):
        \\        self.point = Point(x = x, y = 1)
        \\        self.point.x += 1
        \\        self.values = new list[i64]
        \\        self.values.append(self.point.x)
        \\
        \\func main():
        \\    let scene = Scene(40)
        \\    assert(scene.point.x == 41)
        \\    assert(scene.values[0] == 41)
        \\
    );
}

test "custom init carries function fields aliases lists and maps" {
    try agree.ok(
        \\class Action:
        \\    apply: func(i64) -> i64
        \\    init(apply: func(i64) -> i64):
        \\        self.apply = apply
        \\    func run(value: i64) -> i64:
        \\        return (self.apply)(value)
        \\
        \\func add_one(value: i64) -> i64:
        \\    return value + 1
        \\
        \\alias Operation = Action
        \\
        \\func main():
        \\    let action = Operation(add_one)
        \\    let actions: list[Action] = [action]
        \\    let table: map[str, Action] = {"add": action}
        \\    assert(actions[0].run(20) == 21)
        \\    assert(table["add"].run(41) == 42)
        \\
    );
}

test "fallible custom init cleans unfinished fields and finalizes only finished objects" {
    try agree.prints(
        \\class Resource:
        \\    name: str
        \\    values: list[i64]
        \\    init(name: str, accept: bool) -> !:
        \\        self.name = name
        \\        self.values = [1, 2, 3]
        \\        if not accept:
        \\            error("refused " + name)
        \\    deinit:
        \\        print("closed " + self.name + " " + str(len(self.values)))
        \\
        \\func main() -> !:
        \\    Resource("bad", false) catch reason:
        \\        print(reason)
        \\    if true:
        \\        let resource = try Resource("good", true)
        \\        assert(resource.name == "good")
        \\
    , "refused bad\nclosed good 3\n");
}

test "custom init joins exhaustive matches and handled assignments" {
    try agree.ok(
        \\enum Kind:
        \\    exact
        \\    recovered
        \\
        \\func load(ok: bool) -> i64!:
        \\    if not ok:
        \\        error("missing")
        \\    return 41
        \\
        \\class Score:
        \\    value: i64
        \\    label: str
        \\    init(kind: Kind, ok: bool):
        \\        match kind:
        \\            exact:
        \\                self.value = 42
        \\                self.label = "exact"
        \\            recovered:
        \\                self.value = load(ok) catch:
        \\                    self.value = 41
        \\                self.value += 1
        \\                self.label = "recovered"
        \\
        \\func main():
        \\    let exact = Score(Kind.exact, true)
        \\    let recovered = Score(Kind.recovered, false)
        \\    assert(exact.value == 42 and exact.label == "exact")
        \\    assert(recovered.value == 42 and recovered.label == "recovered")
        \\
    );
}

test "custom initialized classes satisfy interfaces in heterogeneous containers" {
    try agree.ok(
        \\interface Named:
        \\    func name() -> str
        \\
        \\class Person: Named:
        \\    first: str
        \\    last: str
        \\    init(first: str, last: str):
        \\        self.first = first
        \\        self.last = last
        \\    func name() -> str:
        \\        return self.first + " " + self.last
        \\
        \\class Label: Named:
        \\    text: str
        \\    init(text: str):
        \\        self.text = text
        \\    func name() -> str:
        \\        return self.text
        \\
        \\func main():
        \\    var names = new list[Named]
        \\    names.append(Person("Ada", "Lovelace"))
        \\    names.append(Label("Luce"))
        \\    var by_kind = new map[str, Named]
        \\    by_kind["person"] = names[0]
        \\    by_kind["language"] = names[1]
        \\    assert(names[0].name() == "Ada Lovelace")
        \\    assert(by_kind["language"].name() == "Luce")
        \\
    );
}

test "custom init handles recursive references weak defaults static helpers and empty classes" {
    try agree.ok(
        \\class Node:
        \\    value: i64
        \\    next: Node?
        \\    weak parent: Node?
        \\    init(value: i64, next: Node? = none):
        \\        self.value = Node.normalize(value)
        \\        self.next = next
        \\    static func normalize(value: i64) -> i64:
        \\        if value < 0:
        \\            return 0
        \\        return value
        \\
        \\class Marker:
        \\    init():
        \\        return
        \\
        \\func main():
        \\    let tail = Node(-1)
        \\    let head = Node(42, tail)
        \\    let first = Marker()
        \\    let second = Marker()
        \\    assert(head.value == 42)
        \\    let linked = head.next else head
        \\    assert(linked.value == 0 and linked.parent == none)
        \\    assert(not (first is second))
        \\
    );
}

test "a public custom initializer and private state cross a module boundary" {
    const models: agree.File = .{ .name = "models", .source =
        \\class User:
        \\    private:
        \\        name: str
        \\    public:
        \\        init(name: str):
        \\            self.name = name
        \\        func greeting() -> str:
        \\            return "Hello, " + self.name
        \\
    };
    var program = try agree.project(
        \\import models
        \\
        \\func main():
        \\    let user = models.User("Ada")
        \\    assert(user.greeting() == "Hello, Ada")
        \\
    , &.{models});
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

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
