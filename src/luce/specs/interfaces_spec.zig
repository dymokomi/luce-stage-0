//! Nominal interfaces, as an executable specification.
//!
//! The positive cases run through both engines.  Compile-time refusals that
//! protect the contract live beside the other language diagnostics so the
//! interface surface remains exact as it evolves.

const agree = @import("agree.zig");

test "a conforming struct is passed by interface and dispatches its method" {
    try agree.prints(
        \\interface UIElement:
        \\    func render(value: i64) -> i64
        \\
        \\struct UIButton: UIElement:
        \\    let label: str
        \\    func render(value: i64) -> i64:
        \\        return value + 1
        \\
        \\func draw(element: UIElement, value: i64) -> i64:
        \\    return element.render(value)
        \\
        \\func main():
        \\    let button = UIButton(label = "ok")
        \\    print(str(draw(button, 41)))
        \\
    , "42\n");
}

test "lists and maps store different concrete implementations behind one interface" {
    try agree.prints(
        \\interface UIElement:
        \\    func render(value: i64) -> i64
        \\
        \\struct AddOne: UIElement:
        \\    let label: str
        \\    func render(value: i64) -> i64:
        \\        return value + 1
        \\
        \\struct AddTwo: UIElement:
        \\    let label: str
        \\    func render(value: i64) -> i64:
        \\        return value + 2
        \\
        \\func main():
        \\    let one = AddOne(label = "one")
        \\    let two = AddTwo(label = "two")
        \\    var items = list[UIElement]()
        \\    items.append(one)
        \\    items.append(two)
        \\    var table = map[str, UIElement]()
        \\    table["one"] = one
        \\    table["two"] = two
        \\    let from_list = items[1]
        \\    let from_map = table.get("one") else two
        \\    print(str(from_list.render(40)))
        \\    print(str(from_map.render(40)))
        \\
    , "42\n41\n");
}

test "a non-fallible witness can satisfy a fallible interface requirement" {
    try agree.prints(
        \\interface Reader:
        \\    func read(value: i64) -> i64!
        \\
        \\struct Buffer: Reader:
        \\    let marker: i64
        \\    func read(value: i64) -> i64:
        \\        return value + 1
        \\
        \\func use(reader: Reader) -> i64!:
        \\    return try reader.read(41)
        \\
        \\func main() -> !:
        \\    let buffer = Buffer(marker = 0)
        \\    print(str(try use(buffer)))
        \\
    , "42\n");
}

test "a fallible multi-value interface method can be received with try" {
    try agree.prints(
        \\interface Bounds:
        \\    func limits(value: i64) -> (i64, i64)!
        \\
        \\struct Window: Bounds:
        \\    let width: i64
        \\    func limits(value: i64) -> (i64, i64):
        \\        return value, value + self.width
        \\
        \\func total(item: Bounds) -> i64!:
        \\    let low, high = try item.limits(10)
        \\    return low + high
        \\
        \\func main() -> !:
        \\    let window = Window(width = 7)
        \\    print(str(try total(window)))
        \\
    , "27\n");
}

test "an error raised by a class witness crosses the interface call" {
    // Stage-0 regression: the compiled interface call once ran the
    // non-fallible unwind edge, so a raised error unwound like a trap
    // ("trapped and said nothing") instead of reaching catch/try.
    // Covers the value, unit, and try-propagation shapes in one program.
    try agree.prints(
        \\interface Failer:
        \\    func go() -> i64!
        \\    func unit_go() -> !
        \\
        \\class Boom: Failer:
        \\    pub init():
        \\        return
        \\    pub func go() -> i64!:
        \\        error("boom")
        \\    pub func unit_go() -> !:
        \\        error("unit boom")
        \\
        \\func propagate(f: Failer) -> i64!:
        \\    return try f.go()
        \\
        \\func main():
        \\    let f: Failer = Boom()
        \\    f.unit_go() catch reason:
        \\        print("unit: " + reason)
        \\    let v = f.go() catch reason:
        \\        print("caught: " + reason)
        \\        let p = propagate(f) catch propagated:
        \\            print("propagated: " + propagated)
        \\            return
        \\        print("unreachable " + str(p))
        \\        return
        \\    print("unreachable " + str(v))
        \\
    ,
        \\unit: unit boom
        \\caught: boom
        \\propagated: boom
        \\
    );
}

test "an error raised by a mutating witness crosses the interface call" {
    // The inout dispatch shares the fallible edge: a raise leaves the
    // receiver's earlier mutation in place and reaches the caller.
    try agree.prints(
        \\interface Counter:
        \\    mutating func add(amount: i64) -> i64!
        \\
        \\struct Number: Counter:
        \\    var current: i64
        \\    func add(amount: i64) -> i64!:
        \\        self.current = self.current + amount
        \\        if self.current > 100:
        \\            error("overflowed at " + str(self.current))
        \\        return self.current
        \\
        \\func main():
        \\    var counter: Counter = Number(current = 40)
        \\    let first = counter.add(2) catch reason:
        \\        print("unreachable " + reason)
        \\        return
        \\    print(str(first))
        \\    counter.add(70) catch reason:
        \\        print("caught: " + reason)
        \\
    ,
        \\42
        \\caught: overflowed at 112
        \\
    );
}

test "a raising interface method with parameters and a multi-value answer" {
    // Parameters ride behind the hidden receiver, and the multi-value
    // result slot stays untouched on the error path.
    try agree.prints(
        \\interface Bounds:
        \\    func limits(low: i64, label: str) -> (i64, i64)!
        \\
        \\struct Window: Bounds:
        \\    let width: i64
        \\    func limits(low: i64, label: str) -> (i64, i64)!:
        \\        if low < 0:
        \\            error(label + " below zero")
        \\        return low, low + self.width
        \\
        \\func total(item: Bounds, low: i64) -> i64!:
        \\    let a, b = try item.limits(low, "start")
        \\    return a + b
        \\
        \\func main():
        \\    let window = Window(width = 7)
        \\    let good = total(window, 10) catch reason:
        \\        print("unreachable " + reason)
        \\        return
        \\    print(str(good))
        \\    total(window, -1) catch reason:
        \\        print("caught: " + reason)
        \\
    ,
        \\27
        \\caught: start below zero
        \\
    );
}

test "a multi-value interface answer can transfer an owned result field" {
    try agree.ok(
        \\interface Producer:
        \\    func produce(seed: i64) -> (list[i64], i64)
        \\
        \\struct Source: Producer:
        \\    let marker: i64
        \\    func produce(seed: i64) -> (list[i64], i64):
        \\        var values = [seed, seed + 1]
        \\        return values, len(values)
        \\
        \\func main():
        \\    let source = Source(marker = 0)
        \\    let values, count = source.produce(4)
        \\    assert(count == 2)
        \\    assert(values[0] == 4 and values[1] == 5)
        \\
    );
}

test "a multi-method interface dispatches every contract slot" {
    try agree.prints(
        \\interface Drawable:
        \\    func render(value: i64) -> i64
        \\    func label() -> str
        \\
        \\struct Button: Drawable:
        \\    let caption: str
        \\    let offset: i64
        \\    func render(value: i64) -> i64:
        \\        return value + self.offset
        \\    func label() -> str:
        \\        return self.caption
        \\
        \\func describe(item: Drawable) -> str:
        \\    return item.label() + ":" + str(item.render(value = 40))
        \\
        \\func main():
        \\    let button = Button(caption = "ok", offset = 2)
        \\    var current: Drawable = button
        \\    print(describe(current))
        \\    current = Button(caption = "new", offset = 3)
        \\    print(describe(current))
        \\
    , "ok:42\nnew:43\n");
}

test "an interface conversion before a nested carrying argument preserves local order" {
    try agree.prints(
        \\interface Drawable:
        \\    func render(value: i64) -> i64
        \\
        \\struct Button: Drawable:
        \\    let offset: i64
        \\    func render(value: i64) -> i64:
        \\        return value + self.offset
        \\
        \\union Outcome:
        \\    okay(value: i64)
        \\    failed(message: str)
        \\
        \\func read(answer: Outcome) -> i64:
        \\    match answer:
        \\        okay(value):
        \\            return value
        \\        failed(message):
        \\            return len(message)
        \\
        \\func draw(item: Drawable, value: i64) -> i64:
        \\    return item.render(value)
        \\
        \\func main():
        \\    let button = Button(offset = 1)
        \\    print(str(draw(button, read(Outcome.okay(value = 41)))))
        \\
    , "42\n");
}

test "a multi-value method does not invalidate a later method with a carrying argument" {
    try agree.prints(
        \\struct Grid:
        \\    let cells: list[i64]
        \\    func area() -> i64:
        \\        return len(self.cells)
        \\
        \\interface View:
        \\    func measure(size: i64) -> (i64, i64)
        \\    func draw(into: Grid) -> i64
        \\
        \\struct Label: View:
        \\    let width: i64
        \\    func measure(size: i64) -> (i64, i64):
        \\        return size, self.width
        \\    func draw(into: Grid) -> i64:
        \\        return len(into.cells) + self.width
        \\
        \\func render(item: View, grid: Grid) -> i64:
        \\    let rows, columns = item.measure(grid.area())
        \\    return item.draw(grid) + rows + columns
        \\
        \\func main():
        \\    let grid = Grid(cells = [1, 2, 3])
        \\    let label: View = Label(width = 4)
        \\    print(str(render(label, grid)))
        \\
    , "14\n");
}

test "a multi-value interface method uses the ordinary return shape" {
    try agree.prints(
        \\interface Measured:
        \\    func span(value: i64) -> (i64, i64)
        \\
        \\struct Range: Measured:
        \\    let width: i64
        \\    func span(value: i64) -> (i64, i64):
        \\        return value, value + self.width
        \\
        \\func total(item: Measured) -> i64:
        \\    let low, high = item.span(10)
        \\    return low + high
        \\
        \\func main():
        \\    let measurement = Range(width = 7)
        \\    var low: i64 = 0
        \\    var high: i64 = 0
        \\    low, high = measurement.span(10)
        \\    print(str(total(measurement)))
        \\    print(str(low + high))
        \\
    , "27\n27\n");
}

test "one struct may satisfy multiple interfaces" {
    try agree.prints(
        \\interface Named:
        \\    func name() -> str
        \\
        \\interface Sized:
        \\    func size() -> i64
        \\
        \\struct Item: Named, Sized:
        \\    let title: str
        \\    let amount: i64
        \\    func name() -> str:
        \\        return self.title
        \\    func size() -> i64:
        \\        return self.amount
        \\
        \\func show_name(item: Named) -> str:
        \\    return item.name()
        \\
        \\func show_size(item: Sized) -> i64:
        \\    return item.size()
        \\
        \\func main():
        \\    let item = Item(title = "box", amount = 3)
        \\    print(show_name(item))
        \\    print(str(show_size(item)))
        \\
    , "box\n3\n");
}

test "an interface method may answer no value and still dispatch" {
    try agree.prints(
        \\interface Sink:
        \\    func write(value: i64)
        \\
        \\struct Recorder: Sink:
        \\    let marker: i64
        \\    func write(value: i64):
        \\        print(str(value + self.marker))
        \\
        \\func main():
        \\    let sink: Sink = Recorder(marker = 2)
        \\    sink.write(40)
        \\
    , "42\n");
}

test "arrays and struct fields store interface values" {
    try agree.prints(
        \\interface Drawable:
        \\    func render(value: i64) -> i64
        \\
        \\struct Button: Drawable:
        \\    let offset: i64
        \\    func render(value: i64) -> i64:
        \\        return value + self.offset
        \\
        \\struct Panel:
        \\    let element: Drawable
        \\
        \\func main():
        \\    let one = Button(offset = 1)
        \\    let two = Button(offset = 2)
        \\    let panel = Panel(element = one)
        \\    var items = array[Drawable](2)
        \\    items[0] = one
        \\    items[1] = two
        \\    print(str(panel.element.render(40)))
        \\    print(str(items[1].render(40)))
        \\
    , "41\n42\n");
}

test "interface values can be returned and narrowed through an optional" {
    try agree.prints(
        \\interface Drawable:
        \\    func render(value: i64) -> i64
        \\
        \\struct Button: Drawable:
        \\    let offset: i64
        \\    func render(value: i64) -> i64:
        \\        return value + self.offset
        \\
        \\func make() -> Drawable:
        \\    let button = Button(offset = 2)
        \\    return button
        \\
        \\func optional_item(present: bool) -> Drawable?:
        \\    if present:
        \\        return make()
        \\    return none
        \\
        \\func main():
        \\    let maybe = optional_item(true)
        \\    if maybe != none:
        \\        print(str(maybe.render(40)))
        \\
    , "42\n");
}

test "interface methods take object arguments" {
    try agree.prints(
        \\interface Sink:
        \\    func accept(value: list[i64]) -> i64
        \\
        \\struct Collector: Sink:
        \\    let marker: i64
        \\    func accept(value: list[i64]) -> i64:
        \\        return len(value)
        \\
        \\func main():
        \\    let sink = Collector(marker = 0)
        \\    var values = list[i64]()
        \\    values.append(1)
        \\    values.append(2)
        \\    print(str(sink.accept(values)))
        \\
    , "2\n");
}

test "a named carrying receiver can live behind an interface while its owner lives" {
    try agree.prints(
        \\interface Sized:
        \\    func size() -> i64
        \\
        \\struct Box: Sized:
        \\    let values: list[i64]
        \\    func size() -> i64:
        \\        return len(self.values)
        \\
        \\func main():
        \\    var box = Box(values = [1, 2, 3])
        \\    var views = list[Sized]()
        \\    views.append(box)
        \\    print(str(views[0].size()))
        \\
    , "3\n");
}

test "witness slots follow contract order rather than implementation order" {
    try agree.prints(
        \\interface Pair:
        \\    func left() -> str
        \\    func right() -> str
        \\
        \\struct Reversed: Pair:
        \\    let marker: i64
        \\    func right() -> str:
        \\        return "right"
        \\    func left() -> str:
        \\        return "left"
        \\
        \\func main():
        \\    let pair: Pair = Reversed(marker = 0)
        \\    print(pair.left() + "/" + pair.right())
        \\
    , "left/right\n");
}

test "one method can witness two contracts with the same requirement" {
    try agree.prints(
        \\interface Named:
        \\    func text() -> str
        \\
        \\interface Titled:
        \\    func text() -> str
        \\
        \\struct Label: Named, Titled:
        \\    let value: str
        \\    func text() -> str:
        \\        return self.value
        \\
        \\func named(value: Named) -> str:
        \\    return value.text()
        \\
        \\func titled(value: Titled) -> str:
        \\    return value.text()
        \\
        \\func main():
        \\    let label = Label(value = "shared")
        \\    print(named(label) + "/" + titled(label))
        \\
    , "shared/shared\n");
}

test "an interface method can return another owned interface value" {
    try agree.prints(
        \\interface Named:
        \\    func text() -> str
        \\
        \\interface Factory:
        \\    func make(value: i64) -> Named
        \\
        \\class Item: Named:
        \\    let value: i64
        \\    func text() -> str:
        \\        return "item " + str(self.value)
        \\
        \\struct Maker: Factory:
        \\    let offset: i64
        \\    func make(value: i64) -> Named:
        \\        return Item(value = value + self.offset)
        \\
        \\func main():
        \\    let factory: Factory = Maker(offset = 1)
        \\    let made = factory.make(41)
        \\    print(made.text())
        \\
    , "item 42\n");
}

test "replacing heterogeneous class witnesses releases the old receiver first" {
    try agree.prints(
        \\interface Reading:
        \\    func kind() -> str
        \\    func read() -> i64
        \\
        \\class First: Reading:
        \\    let value: i64
        \\    func kind() -> str:
        \\        return "first"
        \\    func read() -> i64:
        \\        return self.value
        \\    deinit:
        \\        print("closed first")
        \\
        \\class Second: Reading:
        \\    let value: i64
        \\    func read() -> i64:
        \\        return self.value
        \\    func kind() -> str:
        \\        return "second"
        \\    deinit:
        \\        print("closed second")
        \\
        \\func main():
        \\    var current: Reading = First(value = 1)
        \\    print(current.kind() + ":" + str(current.read()))
        \\    current = Second(value = 42)
        \\    print(current.kind() + ":" + str(current.read()))
        \\    print("leaving")
        \\
    , "first:1\nclosed first\nsecond:42\nleaving\nclosed second\n");
}

test "a mutating interface requirement preserves one value payload across methods" {
    try agree.prints(
        \\interface Counter:
        \\    mutating func add(amount: i64)
        \\    func value() -> i64
        \\
        \\struct Number: Counter:
        \\    var current: i64
        \\    func add(amount: i64):
        \\        self.current = self.current + amount
        \\    func value() -> i64:
        \\        return self.current
        \\
        \\func main():
        \\    var counter: Counter = Number(current = 1)
        \\    counter.add(1)
        \\    counter.add(40)
        \\    print(str(counter.value()))
        \\
    , "42\n");
}

test "a mutating multi-value requirement uses the ordinary return shape" {
    try agree.prints(
        \\interface Cursor:
        \\    mutating func advance(amount: i64) -> (i64, i64)
        \\    func position() -> i64
        \\
        \\struct Index: Cursor:
        \\    var value: i64
        \\    func advance(amount: i64) -> (i64, i64):
        \\        let before = self.value
        \\        self.value = self.value + amount
        \\        return before, self.value
        \\    func position() -> i64:
        \\        return self.value
        \\
        \\func main():
        \\    var cursor: Cursor = Index(value = 40)
        \\    let before, after = cursor.advance(2)
        \\    print(str(before) + ":" + str(after) + ":" + str(cursor.position()))
        \\
    , "40:42:42\n");
}

test "a non-fallible mutating witness satisfies a fallible requirement" {
    try agree.prints(
        \\interface Counter:
        \\    mutating func add(amount: i64) -> i64!
        \\
        \\struct Number: Counter:
        \\    var current: i64
        \\    func add(amount: i64) -> i64:
        \\        self.current = self.current + amount
        \\        return self.current
        \\
        \\func main() -> !:
        \\    var counter: Counter = Number(current = 40)
        \\    print(str(try counter.add(2)))
        \\
    , "42\n");
}

test "a non-mutating witness can satisfy a mutating requirement" {
    try agree.prints(
        \\interface Reset:
        \\    mutating func reset()
        \\
        \\struct Noop: Reset:
        \\    let marker: i64
        \\    func reset():
        \\        return
        \\
        \\func main():
        \\    var resetter: Reset = Noop(marker = 7)
        \\    resetter.reset()
        \\    print("ok")
        \\
    , "ok\n");
}

test "copied class existentials retain shared identity" {
    try agree.prints(
        \\interface Counter:
        \\    mutating func add(amount: i64)
        \\    func value() -> i64
        \\
        \\class Shared: Counter:
        \\    var current: i64
        \\    func add(amount: i64):
        \\        self.current = self.current + amount
        \\    func value() -> i64:
        \\        return self.current
        \\
        \\func main():
        \\    var first: Counter = Shared(current = 1)
        \\    var second = first
        \\    first.add(41)
        \\    print(str(second.value()))
        \\
    , "42\n");
}

test "a closure can retain and mutate an interface existential" {
    const source =
        \\interface Counter:
        \\    mutating func add(amount: i64)
        \\    func value() -> i64
        \\
        \\struct Number: Counter:
        \\    var current: i64
        \\    func add(amount: i64):
        \\        self.current = self.current + amount
        \\    func value() -> i64:
        \\        return self.current
        \\
        \\func make() -> func() -> i64:
        \\    var counter: Counter = Number(current = 0)
        \\    return func():
        \\        counter.add(1)
        \\        return counter.value()
        \\
        \\func main():
        \\    let next = make()
        \\    print(str(next()))
        \\    print(str(next()))
        \\
    ;
    try agree.prints(source, "1\n2\n");
}

test "copied struct existentials mutate independently" {
    try agree.prints(
        \\interface Counter:
        \\    mutating func add(amount: i64)
        \\    func value() -> i64
        \\
        \\struct Number: Counter:
        \\    var current: i64
        \\    func add(amount: i64):
        \\        self.current = self.current + amount
        \\    func value() -> i64:
        \\        return self.current
        \\
        \\func main():
        \\    var first: Counter = Number(current = 1)
        \\    var second = first
        \\    first.add(41)
        \\    second.add(1)
        \\    print(str(first.value()) + ":" + str(second.value()))
        \\
    , "42:2\n");
}

test "heterogeneous collections can round-trip mutating interface values" {
    try agree.prints(
        \\interface Counter:
        \\    mutating func add(amount: i64)
        \\    func value() -> i64
        \\
        \\struct Number: Counter:
        \\    var current: i64
        \\    func add(amount: i64):
        \\        self.current = self.current + amount
        \\    func value() -> i64:
        \\        return self.current
        \\
        \\struct Offset: Counter:
        \\    var current: i64
        \\    func add(amount: i64):
        \\        self = Offset(current = self.current + amount + 1)
        \\    func value() -> i64:
        \\        return self.current
        \\
        \\func main():
        \\    var items = list[Counter]()
        \\    items.append(Number(current = 1))
        \\    items.append(Offset(current = 39))
        \\    var first = items[0]
        \\    var second = items[1]
        \\    first.add(1)
        \\    second.add(1)
        \\    items[0] = first
        \\    items[1] = second
        \\    var table = map[str, Counter]()
        \\    table["first"] = items[0]
        \\    table["second"] = items[1]
        \\    let fallback: Counter = Number(current = 0)
        \\    let from_first = table.get("first") else fallback
        \\    let from_second = table.get("second") else fallback
        \\    print(str(from_first.value()) + ":" + str(from_second.value()))
        \\
    , "2:41\n");
}
