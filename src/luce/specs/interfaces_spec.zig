//! Nominal interfaces, as an executable specification.
//!
//! The positive cases run through both engines.  Compile-time refusals that
//! protect the contract live beside the other language diagnostics so the
//! interface surface remains exact as it evolves.

const agree = @import("agree.zig");

test "a conforming struct is passed by interface and dispatches its method" {
    try agree.prints(
        \\interface UIElement:
        \\    func render(value: long) -> long
        \\
        \\struct UIButton: UIElement:
        \\    label: string
        \\    func render(value: long) -> long:
        \\        return value + 1
        \\
        \\func draw(element: UIElement, value: long) -> long:
        \\    return element.render(value)
        \\
        \\func main():
        \\    let button = UIButton(label = "ok")
        \\    print(string(draw(button, 41)))
        \\
    , "42\n");
}

test "lists and maps store different concrete implementations behind one interface" {
    try agree.prints(
        \\interface UIElement:
        \\    func render(value: long) -> long
        \\
        \\struct AddOne: UIElement:
        \\    label: string
        \\    func render(value: long) -> long:
        \\        return value + 1
        \\
        \\struct AddTwo: UIElement:
        \\    label: string
        \\    func render(value: long) -> long:
        \\        return value + 2
        \\
        \\func main():
        \\    let one = AddOne(label = "one")
        \\    let two = AddTwo(label = "two")
        \\    var items = new list(UIElement)
        \\    items.append(one)
        \\    items.append(two)
        \\    var table = new map(string, UIElement)
        \\    table["one"] = one
        \\    table["two"] = two
        \\    let from_list = items[1]
        \\    let from_map = table.get("one") else two
        \\    print(string(from_list.render(40)))
        \\    print(string(from_map.render(40)))
        \\
    , "42\n41\n");
}

test "a non-fallible witness can satisfy a fallible interface requirement" {
    try agree.prints(
        \\interface Reader:
        \\    func read(value: long) -> long!
        \\
        \\struct Buffer: Reader:
        \\    marker: long
        \\    func read(value: long) -> long:
        \\        return value + 1
        \\
        \\func use(reader: Reader) -> long!:
        \\    return try reader.read(41)
        \\
        \\func main() -> !:
        \\    let buffer = Buffer(marker = 0)
        \\    print(string(try use(buffer)))
        \\
    , "42\n");
}

test "a fallible multi-value interface method can be received with try" {
    try agree.prints(
        \\interface Bounds:
        \\    func limits(value: long) -> (long, long)!
        \\
        \\struct Window: Bounds:
        \\    width: long
        \\    func limits(value: long) -> (long, long):
        \\        return value, value + self.width
        \\
        \\func total(item: Bounds) -> long!:
        \\    let low, high = try item.limits(10)
        \\    return low + high
        \\
        \\func main() -> !:
        \\    let window = Window(width = 7)
        \\    print(string(try total(window)))
        \\
    , "27\n");
}

test "a multi-value interface answer can transfer an owned result field" {
    try agree.ok(
        \\interface Producer:
        \\    func produce(seed: long) -> (list(long), long)
        \\
        \\struct Source: Producer:
        \\    marker: long
        \\    func produce(seed: long) -> (list(long), long):
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
        \\    func render(value: long) -> long
        \\    func label() -> string
        \\
        \\struct Button: Drawable:
        \\    caption: string
        \\    offset: long
        \\    func render(value: long) -> long:
        \\        return value + self.offset
        \\    func label() -> string:
        \\        return self.caption
        \\
        \\func describe(item: Drawable) -> string:
        \\    return item.label() + ":" + string(item.render(value = 40))
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

test "a multi-value method does not invalidate a later method with a carrying argument" {
    try agree.prints(
        \\struct Grid:
        \\    cells: list(long)
        \\    func area() -> long:
        \\        return len(self.cells)
        \\
        \\interface View:
        \\    func measure(size: long) -> (long, long)
        \\    func draw(into: Grid) -> long
        \\
        \\struct Label: View:
        \\    width: long
        \\    func measure(size: long) -> (long, long):
        \\        return size, self.width
        \\    func draw(into: Grid) -> long:
        \\        return len(into.cells) + self.width
        \\
        \\func render(item: View, grid: Grid) -> long:
        \\    let rows, columns = item.measure(grid.area())
        \\    return item.draw(grid) + rows + columns
        \\
        \\func main():
        \\    let grid = Grid(cells = [1, 2, 3])
        \\    let label: View = Label(width = 4)
        \\    print(string(render(label, grid)))
        \\
    , "14\n");
}

test "a multi-value interface method uses the ordinary return shape" {
    try agree.prints(
        \\interface Measured:
        \\    func span(value: long) -> (long, long)
        \\
        \\struct Range: Measured:
        \\    width: long
        \\    func span(value: long) -> (long, long):
        \\        return value, value + self.width
        \\
        \\func total(item: Measured) -> long:
        \\    let low, high = item.span(10)
        \\    return low + high
        \\
        \\func main():
        \\    let measurement = Range(width = 7)
        \\    var low: long = 0
        \\    var high: long = 0
        \\    low, high = measurement.span(10)
        \\    print(string(total(measurement)))
        \\    print(string(low + high))
        \\
    , "27\n27\n");
}

test "one struct may satisfy multiple interfaces" {
    try agree.prints(
        \\interface Named:
        \\    func name() -> string
        \\
        \\interface Sized:
        \\    func size() -> long
        \\
        \\struct Item: Named, Sized:
        \\    title: string
        \\    amount: long
        \\    func name() -> string:
        \\        return self.title
        \\    func size() -> long:
        \\        return self.amount
        \\
        \\func show_name(item: Named) -> string:
        \\    return item.name()
        \\
        \\func show_size(item: Sized) -> long:
        \\    return item.size()
        \\
        \\func main():
        \\    let item = Item(title = "box", amount = 3)
        \\    print(show_name(item))
        \\    print(string(show_size(item)))
        \\
    , "box\n3\n");
}

test "an interface method may answer no value and still dispatch" {
    try agree.prints(
        \\interface Sink:
        \\    func write(value: long)
        \\
        \\struct Recorder: Sink:
        \\    marker: long
        \\    func write(value: long):
        \\        print(string(value + self.marker))
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
        \\    func render(value: long) -> long
        \\
        \\struct Button: Drawable:
        \\    offset: long
        \\    func render(value: long) -> long:
        \\        return value + self.offset
        \\
        \\struct Panel:
        \\    element: Drawable
        \\
        \\func main():
        \\    let one = Button(offset = 1)
        \\    let two = Button(offset = 2)
        \\    let panel = Panel(element = one)
        \\    var items = new array(Drawable, 2)
        \\    items[0] = one
        \\    items[1] = two
        \\    print(string(panel.element.render(40)))
        \\    print(string(items[1].render(40)))
        \\
    , "41\n42\n");
}

test "interface values can be returned and narrowed through an optional" {
    try agree.prints(
        \\interface Drawable:
        \\    func render(value: long) -> long
        \\
        \\struct Button: Drawable:
        \\    offset: long
        \\    func render(value: long) -> long:
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
        \\        print(string(maybe.render(40)))
        \\
    , "42\n");
}

test "interface methods can take ownership of object arguments" {
    try agree.prints(
        \\interface Sink:
        \\    func accept(value: give list(long)) -> long
        \\
        \\struct Collector: Sink:
        \\    marker: long
        \\    func accept(value: give list(long)) -> long:
        \\        return len(value)
        \\
        \\func main():
        \\    let sink = Collector(marker = 0)
        \\    var values = new list(long)
        \\    values.append(1)
        \\    values.append(2)
        \\    print(string(sink.accept(give values)))
        \\
    , "2\n");
}

test "a named carrying receiver can live behind an interface while its owner lives" {
    try agree.prints(
        \\interface Sized:
        \\    func size() -> long
        \\
        \\struct Box: Sized:
        \\    values: list(long)
        \\    func size() -> long:
        \\        return len(self.values)
        \\
        \\func main():
        \\    var box = Box(values = [1, 2, 3])
        \\    var views = new list(Sized)
        \\    views.append(box)
        \\    print(string(views[0].size()))
        \\
    , "3\n");
}
