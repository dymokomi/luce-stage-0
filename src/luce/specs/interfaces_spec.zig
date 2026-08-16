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
        \\    label: str
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
        \\    label: str
        \\    func render(value: i64) -> i64:
        \\        return value + 1
        \\
        \\struct AddTwo: UIElement:
        \\    label: str
        \\    func render(value: i64) -> i64:
        \\        return value + 2
        \\
        \\func main():
        \\    let one = AddOne(label = "one")
        \\    let two = AddTwo(label = "two")
        \\    var items = new list[UIElement]
        \\    items.append(one)
        \\    items.append(two)
        \\    var table = new map[str, UIElement]
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
        \\    marker: i64
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
        \\    width: i64
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

test "a multi-value interface answer can transfer an owned result field" {
    try agree.ok(
        \\interface Producer:
        \\    func produce(seed: i64) -> (list[i64], i64)
        \\
        \\struct Source: Producer:
        \\    marker: i64
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
        \\    caption: str
        \\    offset: i64
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
        \\    offset: i64
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
        \\    cells: list[i64]
        \\    func area() -> i64:
        \\        return len(self.cells)
        \\
        \\interface View:
        \\    func measure(size: i64) -> (i64, i64)
        \\    func draw(into: Grid) -> i64
        \\
        \\struct Label: View:
        \\    width: i64
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
        \\    width: i64
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
        \\    title: str
        \\    amount: i64
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
        \\    marker: i64
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
        \\    offset: i64
        \\    func render(value: i64) -> i64:
        \\        return value + self.offset
        \\
        \\struct Panel:
        \\    element: Drawable
        \\
        \\func main():
        \\    let one = Button(offset = 1)
        \\    let two = Button(offset = 2)
        \\    let panel = Panel(element = one)
        \\    var items = new array[Drawable](2)
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
        \\    offset: i64
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
        \\    marker: i64
        \\    func accept(value: list[i64]) -> i64:
        \\        return len(value)
        \\
        \\func main():
        \\    let sink = Collector(marker = 0)
        \\    var values = new list[i64]
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
        \\    values: list[i64]
        \\    func size() -> i64:
        \\        return len(self.values)
        \\
        \\func main():
        \\    var box = Box(values = [1, 2, 3])
        \\    var views = new list[Sized]
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
        \\    marker: i64
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
        \\    value: str
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
        \\    value: i64
        \\    func text() -> str:
        \\        return "item " + str(self.value)
        \\
        \\struct Maker: Factory:
        \\    offset: i64
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
        \\    value: i64
        \\    func kind() -> str:
        \\        return "first"
        \\    func read() -> i64:
        \\        return self.value
        \\    deinit:
        \\        print("closed first")
        \\
        \\class Second: Reading:
        \\    value: i64
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
