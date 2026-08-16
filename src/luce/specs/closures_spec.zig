//! Capturing block closures, executed on both engines.

const agree = @import("agree.zig");

test "closure: immutable and mutable captures survive their writing scope" {
    try agree.prints(
        \\func make_adder(start: i64) -> func(i64) -> i64:
        \\    var total = start
        \\    let advance: func(i64) -> i64 = func(amount):
        \\        total += amount
        \\        return total
        \\    return advance
        \\
        \\func main():
        \\    let add: func(i64) -> i64 = make_adder(10)
        \\    print(str(add(2)))
        \\    print(str(add(5)))
        \\
    , "12\n17\n");
}

test "closure: immutable captures are retained by the environment" {
    try agree.prints(
        \\func make_label(prefix: str) -> func(i64) -> str:
        \\    return func(number):
        \\        return prefix + str(number)
        \\
        \\func main():
        \\    let label: func(i64) -> str = make_label("item ")
        \\    print(label(7))
        \\
    , "item 7\n");
}

test "closure: a capture-free block closure can return no value" {
    try agree.ok(
        \\func main():
        \\    let operation: func(i64) = func(value):
        \\        assert(value == 42)
        \\    operation(42)
        \\
    );
}

test "closure: capturing self keeps a class alive until the function dies" {
    try agree.prints(
        \\class Counter:
        \\    value: i64
        \\    func reader() -> func() -> i64:
        \\        return func():
        \\            return self.value
        \\    deinit:
        \\        print("closed")
        \\
        \\func make_reader() -> func() -> i64:
        \\    let counter = Counter(value = 42)
        \\    return counter.reader()
        \\
        \\func main():
        \\    let read: func() -> i64 = make_reader()
        \\    print(str(read()))
        \\
    , "42\nclosed\n");
}

test "closure: a capture list snapshot is evaluated exactly once" {
    try agree.ok(
        \\func main():
        \\    var number = 1
        \\    let read: func() -> i64 = [copy = number] func():
        \\        return copy
        \\    number = 42
        \\    assert(read() == 1)
        \\    assert(number == 42)
        \\
    );
}

test "closure: a weak capture zeros while a strong capture retains" {
    try agree.prints(
        \\class Item:
        \\    value: i64
        \\    deinit:
        \\        print("closed " + str(self.value))
        \\
        \\func main():
        \\    var weak_read: (func() -> i64)? = none
        \\    var strong_read: (func() -> i64)? = none
        \\    if true:
        \\        let weak_item = Item(value = 7)
        \\        let strong_item = Item(value = 35)
        \\        weak_read = [weak weak_item] func():
        \\            let live = weak_item else Item(value = 0)
        \\            return live.value
        \\        strong_read = func():
        \\            return strong_item.value
        \\        assert(weak_read() == 7)
        \\    let call_weak = weak_read else () -> -1
        \\    let call_strong = strong_read else () -> -1
        \\    print(str(call_weak()))
        \\    print(str(call_strong()))
        \\
    , "closed 7\nclosed 0\n0\n35\nclosed 35\n");
}

test "closure: function-valued captures dispatch through their own environment" {
    try agree.prints(
        \\func twice(value: i64) -> i64:
        \\    return value * 2
        \\
        \\func wrap(operation: func(i64) -> i64, offset: i64) -> func(i64) -> i64:
        \\    return func(value):
        \\        return operation(value) + offset
        \\
        \\func main():
        \\    let calculate: func(i64) -> i64 = wrap(twice, 2)
        \\    print(str(calculate(20)))
        \\
    , "42\n");
}

test "closure: different closures share one mutable cell" {
    try agree.ok(
        \\struct Pair:
        \\    add: (func(i64) -> i64)?
        \\    read: (func() -> i64)?
        \\
        \\func make_pair() -> Pair:
        \\    var total = 0
        \\    let add: func(i64) -> i64 = func(amount):
        \\        total += amount
        \\        return total
        \\    let read: func() -> i64 = func():
        \\        return total
        \\    return Pair(add = add, read = read)
        \\
        \\func main():
        \\    let pair = make_pair()
        \\    let add = pair.add else (value) -> value
        \\    let read = pair.read else () -> -1
        \\    assert(add(40) == 40)
        \\    assert(add(2) == 42)
        \\    assert(read() == 42)
        \\
    );
}

test "closure: nested closures carry outer captures and inner mutable cells" {
    try agree.ok(
        \\func factory(base: i64) -> func(i64) -> func() -> i64:
        \\    return func(offset):
        \\        var calls = 0
        \\        return func():
        \\            calls += 1
        \\            return base + offset + calls
        \\
        \\func main():
        \\    let make: func(i64) -> func() -> i64 = factory(39)
        \\    let first: func() -> i64 = make(1)
        \\    let second: func() -> i64 = make(10)
        \\    assert(first() == 41)
        \\    assert(first() == 42)
        \\    assert(second() == 50)
        \\
    );
}

test "closure: lists, maps, and arrays hold heterogeneous environments" {
    try agree.ok(
        \\func make_add(amount: i64) -> func(i64) -> i64:
        \\    return func(value):
        \\        return value + amount
        \\
        \\func main():
        \\    let add_one: func(i64) -> i64 = make_add(1)
        \\    let add_two: func(i64) -> i64 = make_add(2)
        \\    var functions = new list[(func(i64) -> i64)?]
        \\    functions.append(add_one)
        \\    functions.append(add_two)
        \\    var named = new map[str, func(i64) -> i64]
        \\    named["one"] = add_one
        \\    named["two"] = add_two
        \\    var cells = new array[(func(i64) -> i64)?](2)
        \\    cells[0] = add_one
        \\    cells[1] = add_two
        \\    let first = functions[0] else (value) -> value
        \\    let second = functions[1] else (value) -> value
        \\    let array_first = cells[0] else (value) -> value
        \\    let array_second = cells[1] else (value) -> value
        \\    assert(first(40) == 41)
        \\    assert(second(40) == 42)
        \\    assert(named["one"](41) == 42)
        \\    assert(array_first(41) == 42)
        \\    assert(array_second(40) == 42)
        \\
    );
}

test "closure: guarded assignment updates its cell only on success" {
    try agree.ok(
        \\func next(ok: bool, value: i64) -> i64!:
        \\    if not ok:
        \\        error("no value")
        \\    return value + 1
        \\
        \\func make_counter() -> func(bool) -> i64:
        \\    var value = 40
        \\    return func(ok):
        \\        value = next(ok, value) catch:
        \\            return value
        \\        return value
        \\
        \\func main():
        \\    let advance: func(bool) -> i64 = make_counter()
        \\    assert(advance(true) == 41)
        \\    assert(advance(false) == 41)
        \\    assert(advance(true) == 42)
        \\
    );
}

test "closure: outer and closure writes share one scalar cell" {
    try agree.ok(
        \\func main():
        \\    var number = 1
        \\    let update: func(i64) -> i64 = func(amount):
        \\        number += amount
        \\        return number
        \\    number = 40
        \\    assert(update(2) == 42)
        \\    assert(number == 42)
        \\
    );
}

test "closure: outer and closure writes share one text cell" {
    try agree.ok(
        \\func main():
        \\    var text = "a"
        \\    let update: func(str) -> str = func(suffix):
        \\        text += suffix
        \\        return text
        \\    text = "x"
        \\    assert(update("b") == "xb")
        \\    assert(text == "xb")
        \\
    );
}

test "closure: outer and closure writes share one value-struct cell" {
    try agree.ok(
        \\struct State:
        \\    count: i64
        \\    label: str
        \\
        \\func main():
        \\    var state = State(count = 1, label = "a")
        \\    let update: func(i64) -> i64 = func(amount):
        \\        state.count += amount
        \\        state.label += "b"
        \\        return state.count
        \\    state.count = 40
        \\    state.label = "x"
        \\    assert(update(2) == 42)
        \\    assert(state.count == 42)
        \\    assert(state.label == "xb")
        \\
    );
}

test "closure: outer and closure writes share one optional cell" {
    try agree.ok(
        \\func main():
        \\    var maybe: i64? = none
        \\    let update: func(i64) -> i64 = func(value):
        \\        maybe = value
        \\        return maybe
        \\    maybe = 40
        \\    assert(update(42) == 42)
        \\    assert(maybe == 42)
        \\
    );
}

test "closure: outer writes and closure writes share scalar str struct and optional cells" {
    try agree.prints(
        \\struct State:
        \\    count: i64
        \\    label: str
        \\
        \\func main():
        \\    var number = 1
        \\    var text = "a"
        \\    var state = State(count = 2, label = "s")
        \\    var maybe: i64? = none
        \\    let update: func(i64) -> i64 = func(amount):
        \\        number += amount
        \\        text += "b"
        \\        state.count += amount
        \\        state.label += text
        \\        maybe = number + state.count
        \\        return maybe + len(text) + len(state.label)
        \\    number = 10
        \\    text = "x"
        \\    state.count = 20
        \\    state.label = "q"
        \\    print(str(update(5)))
        \\    print(str(number))
        \\    print(text)
        \\    print(str(state.count))
        \\    print(state.label)
        \\    print(str(maybe else 0))
        \\
    , "45\n15\nxb\n25\nqxb\n40\n");
}

test "closure: a captured weak variable remains weak across both writers" {
    try agree.ok(
        \\func main():
        \\    weak var observed: list[i64]? = none
        \\    let read: func() -> i64 = func():
        \\        let snapshot = observed else [0]
        \\        return snapshot[0]
        \\    if true:
        \\        let first = [41]
        \\        observed = first
        \\        assert(read() == 41)
        \\    assert(read() == 0)
        \\    let set_and_read: func(list[i64]) -> i64 = func(value):
        \\        observed = value
        \\        return read()
        \\    let second = [42]
        \\    assert(set_and_read(second) == 42)
        \\
    );
}

test "closure: an interface capture retains its complete dispatch state" {
    try agree.prints(
        \\interface Scorer:
        \\    func score(value: i64) -> i64
        \\
        \\class Scale: Scorer:
        \\    factor: i64
        \\    func score(value: i64) -> i64:
        \\        return value * self.factor
        \\    deinit:
        \\        print("closed")
        \\
        \\func wrap(item: Scorer) -> func(i64) -> i64:
        \\    return func(value):
        \\        return item.score(value)
        \\
        \\func main():
        \\    let scale = Scale(factor = 2)
        \\    let calculate: func(i64) -> i64 = wrap(scale)
        \\    assert(calculate(21) == 42)
        \\
    , "closed\n");
}

test "closure: a bound-method capture retains and releases its receiver" {
    try agree.ok(
        \\class Scale:
        \\    factor: i64
        \\    func score(value: i64) -> i64:
        \\        return value * self.factor
        \\
        \\func wrap(operation: func(i64) -> i64) -> func(i64) -> i64:
        \\    return func(value):
        \\        return operation(value)
        \\
        \\func main():
        \\    let scale = Scale(factor = 2)
        \\    let bound: func(i64) -> i64 = scale.score
        \\    let calculate: func(i64) -> i64 = wrap(bound)
        \\    assert(calculate(21) == 42)
        \\
    );
}

test "closure: a late mutable declaration initializes its canonical cell" {
    try agree.ok(
        \\func main():
        \\    var text: str
        \\    let add_suffix: func(str) -> str = func(suffix):
        \\        text += suffix
        \\        return text
        \\    assert(text == "")
        \\    text = "forty"
        \\    assert(add_suffix("-two") == "forty-two")
        \\    assert(text == "forty-two")
        \\
    );
}

test "closure: destructured mutables transfer independently into shared cells" {
    try agree.ok(
        \\func initial() -> (str, i64):
        \\    return "forty", 40
        \\
        \\func main():
        \\    var text, number = initial()
        \\    let finish: func() -> str = func():
        \\        text += "-two"
        \\        number += 2
        \\        return text + ":" + str(number)
        \\    assert(finish() == "forty-two:42")
        \\    assert(text == "forty-two")
        \\    assert(number == 42)
        \\
    );
}

test "closure: weak self breaks a stored callback cycle and zeros afterward" {
    try agree.prints(
        \\class Node:
        \\    value: i64
        \\    callback: (func() -> i64)?
        \\    func install():
        \\        self.callback = [weak self] func():
        \\            let live = self else Node(value = 0, callback = none)
        \\            return live.value
        \\    deinit:
        \\        print("closed " + str(self.value))
        \\
        \\func main():
        \\    var callback: (func() -> i64)? = none
        \\    if true:
        \\        let node = Node(value = 42, callback = none)
        \\        node.install()
        \\        let installed = node.callback else () -> -1
        \\        callback = installed
        \\        assert(installed() == 42)
        \\    let read = callback else () -> -1
        \\    assert(read() == 0)
        \\
    , "closed 42\nclosed 0\n");
}
