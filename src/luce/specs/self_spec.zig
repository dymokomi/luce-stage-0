//! Implied receiver semantics, on both execution engines.
//!
//! Plain struct and enum members receive `self`; `static func` members
//! do not. Whether a method writes its receiver is inferred to a fixed
//! point, and a writer aliases one bare caller-owned `var` in place.

const agree = @import("agree.zig");

test "self: implied receiver reads and writes a bare var binding" {
    try agree.ok(
        \\struct Counter:
        \\    value: long
        \\
        \\    func read() -> long:
        \\        return self.value
        \\
        \\    func bump():
        \\        self.value += 1
        \\
        \\func main():
        \\    var counter = Counter(value = 4)
        \\    assert(counter.read() == 4)
        \\    counter.bump()
        \\    assert(counter.read() == 5)
        \\
    );
}

test "self: writer inference reaches a fixed point across forward transitive calls" {
    try agree.ok(
        \\struct Counter:
        \\    value: long
        \\
        \\    func outer():
        \\        self.middle()
        \\
        \\    func middle():
        \\        self.leaf()
        \\
        \\    func leaf():
        \\        self.value += 1
        \\
        \\func main():
        \\    var counter = Counter(value = 0)
        \\    counter.outer()
        \\    assert(counter.value == 1)
        \\
    );
}

test "self: writer inference includes calls made while evaluating assignment places" {
    try agree.ok(
        \\struct Cell:
        \\    value: long
        \\
        \\struct Cursor:
        \\    at: long
        \\
        \\    func write(items: list(long)):
        \\        items[self.bump()] = 0
        \\
        \\    func write_nested(cells: list(Cell)):
        \\        cells[self.bump()].value = 0
        \\
        \\    func bump() -> long:
        \\        let previous = self.at
        \\        self.at += 1
        \\        return previous
        \\
        \\func main():
        \\    var cursor = Cursor(at = 0)
        \\    var items: list(long) = [7, 8, 9]
        \\    var cells = [Cell(value = 4), Cell(value = 5), Cell(value = 6)]
        \\    cursor.write(items)
        \\    cursor.write_nested(cells)
        \\    assert(cursor.at == 2)
        \\    assert(items[0] == 0 and items[1] == 8)
        \\    assert(cells[0].value == 4 and cells[1].value == 0)
        \\    free(items)
        \\    free(cells)
        \\
    );
}

test "self: mutating object contents is a reader and works through let" {
    try agree.ok(
        \\struct Bag:
        \\    items: list(long)
        \\
        \\    func add(value: long):
        \\        self.items.append(value)
        \\
        \\func main():
        \\    let bag = Bag(items = [1])
        \\    bag.add(2)
        \\    assert(len(bag.items) == 2)
        \\    assert(bag.items[0] == 1 and bag.items[1] == 2)
        \\
    );
}

test "self: an owning object-carry receiver may replace a field and its whole value" {
    try agree.ok(
        \\struct Box:
        \\    items: list(long)
        \\    label: string
        \\
        \\    func replace_field(value: long):
        \\        self.items = [value]
        \\
        \\    func replace_whole(value: long):
        \\        self = Box(
        \\            items = [value, value + 1],
        \\            label = "a replacement label long enough to own outside bytes",
        \\        )
        \\
        \\func main():
        \\    var box = Box(
        \\        items = [1, 2, 3],
        \\        label = "the original label is also long enough to own outside bytes",
        \\    )
        \\    box.replace_field(7)
        \\    assert(len(box.items) == 1 and box.items[0] == 7)
        \\    box.replace_whole(9)
        \\    assert(len(box.items) == 2)
        \\    assert(box.items[0] == 9 and box.items[1] == 10)
        \\    assert(box.label == "a replacement label long enough to own outside bytes")
        \\
    );
}

test "self: multi-return assignment to self infers an object-carrying writer" {
    try agree.ok(
        \\struct Box:
        \\    items: list(long)
        \\
        \\    func refresh(value: long) -> long:
        \\        var answer: long = 0
        \\        self, answer = fresh_pair(value)
        \\        return answer
        \\
        \\func fresh_pair(value: long) -> (Box, long):
        \\    return Box(items = [value, value + 1]), value * 10
        \\
        \\func main():
        \\    var box = Box(items = [1, 2, 3])
        \\    assert(box.refresh(7) == 70)
        \\    assert(len(box.items) == 2 and box.items[0] == 7 and box.items[1] == 8)
        \\    assert(box.refresh(9) == 90)
        \\    assert(len(box.items) == 2 and box.items[0] == 9 and box.items[1] == 10)
        \\
    );
}

test "self: writes before a fallible method errors remain visible" {
    try agree.ok(
        \\struct Meter:
        \\    reading: long
        \\
        \\    func fail_after_write() -> !:
        \\        self.reading += 1
        \\        error("stopped")
        \\
        \\func main():
        \\    var meter = Meter(reading = 10)
        \\    meter.fail_after_write() catch reason:
        \\        assert(reason == "stopped")
        \\    assert(meter.reading == 11)
        \\
    );
}

test "self: writers support zero one and multiple declared return values" {
    try agree.ok(
        \\struct Counter:
        \\    value: long
        \\
        \\    func zero():
        \\        self.value += 1
        \\
        \\    func one() -> long:
        \\        self.value += 1
        \\        return self.value
        \\
        \\    func pair() -> (long, long):
        \\        self.value += 1
        \\        return self.value, self.value * 2
        \\
        \\func main():
        \\    var counter = Counter(value = 0)
        \\    counter.zero()
        \\    let one = counter.one()
        \\    let left, right = counter.pair()
        \\    assert(counter.value == 3)
        \\    assert(one == 2 and left == 3 and right == 6)
        \\    counter.pair()
        \\    assert(counter.value == 4)
        \\
    );
}

test "self: an enum method may replace its whole implied receiver" {
    try agree.ok(
        \\enum Light:
        \\    red
        \\    green
        \\
        \\    func flip():
        \\        match self:
        \\            red:
        \\                self = Light.green
        \\            green:
        \\                self = Light.red
        \\
        \\func main():
        \\    var light = Light.red
        \\    light.flip()
        \\    assert(light == Light.green)
        \\    light.flip()
        \\    assert(light == Light.red)
        \\
    );
}

test "self: a static member is a function value and a spawn target" {
    try agree.ok(
        \\struct Math:
        \\    static func twice(value: long) -> long:
        \\        return value * 2
        \\
        \\func main():
        \\    let chosen: func(long) -> long = Math.twice
        \\    assert(chosen(5) == 10)
        \\    let work = spawn Math.twice(21)
        \\    assert(work.wait() == 42)
        \\
    );
}

test "self: writer results with owned storage survive binding and statement discard" {
    try agree.ok(
        \\struct Payload:
        \\    items: list(long)
        \\
        \\struct Maker:
        \\    made: long
        \\
        \\    func text() -> string:
        \\        self.made += 1
        \\        return "a heap-backed string returned from writer number " + string(self.made)
        \\
        \\    func payload() -> Payload:
        \\        self.made += 1
        \\        return Payload(items = [self.made, self.made + 1])
        \\
        \\func main():
        \\    var maker = Maker(made = 0)
        \\    let text = maker.text()
        \\    assert(text == "a heap-backed string returned from writer number 1")
        \\    maker.text()
        \\    let payload = maker.payload()
        \\    assert(payload.items[0] == 3 and payload.items[1] == 4)
        \\    maker.payload()
        \\    assert(maker.made == 4)
        \\
    );
}

test "self: an earlier optional string argument outlives a later receiver write" {
    try agree.ok(
        \\let first_text = "the first optional string is long enough to live in owned outside storage"
        \\let second_text = "the second optional string is likewise long enough to live outside inline storage"
        \\let replacement = "the replacement string is long enough to require outside owned storage too"
        \\
        \\struct Box:
        \\    text: string?
        \\
        \\    func clear() -> long:
        \\        self.text = none
        \\        return 1
        \\
        \\    func replace() -> long:
        \\        self.text = replacement
        \\        return 2
        \\
        \\func saw(value: string, effect: long, expected: string) -> bool:
        \\    return value == expected and effect > 0
        \\
        \\func main():
        \\    var box = Box(text = first_text)
        \\    assert(saw(box.text else "fallback", box.clear(), first_text))
        \\    assert(box.text == none)
        \\    box.text = second_text
        \\    assert(saw(box.text else "fallback", box.replace(), second_text))
        \\    assert((box.text else "missing") == replacement)
        \\
    );
}

test "self: writer arguments borrowed from the receiver outlive whole-self replacement" {
    try agree.ok(
        \\let original = "the original receiver string is long enough to require owned outside storage"
        \\let replacement = "the replacement receiver string is also long enough to require outside storage"
        \\
        \\struct Box:
        \\    text: string
        \\
        \\    func replace(previous_text: string, previous_box: Box) -> bool:
        \\        self = Box(text = replacement)
        \\        return previous_text == original and previous_box.text == original
        \\
        \\func main():
        \\    var box = Box(text = original)
        \\    assert(box.replace(box.text, box))
        \\    assert(box.text == replacement)
        \\
    );
}
