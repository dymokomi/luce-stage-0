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
