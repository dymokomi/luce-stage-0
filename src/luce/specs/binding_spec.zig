//! Bound methods, as an executable specification (docs/BINDING.md).
//!
//! Every fact below is proved on **both engines** — the interpreter and
//! the compiled artifact, run and compared on prints, trap code, trap
//! message, call trace frame for frame, leak census and the world each
//! left behind (`agree.zig`).  That bar is what D12 is for: a function
//! value is a two-slot run holding the function it names and the
//! receiver it carries, and the two engines build that run in different
//! code — one calling `libluce_rt` from a dispatch loop, one emitting
//! the same call — so a disagreement here is a bug in one arm rather
//! than a difference of pretence.
//!
//! What is proved, in the order the design states it:
//!
//!   * **D1/D2** — `receiver.method` written where a `func` type lands
//!     is a function value, with the receiver's parameter dropped from
//!     the written signature and no marker anywhere.
//!   * **D3** — a value-only receiver is copied at the bind: the value
//!     is a plain value from then on, it copies freely, it takes no
//!     verbs, and the receiver it carries is its own — writing the
//!     original afterwards does not reach it.
//!   * **D4, as amended** — a carrying receiver owns retained references:
//!     handles inside the copied receiver alias the same graph (S26), and
//!     ARC keeps that graph alive as long as the function value.
//!   * **D6** — `str(f)` answers the method's qualified name.
//!   * **D11** — a union member constructor is a function value, with
//!     the payload fields as parameters; a payload-less member stays a
//!     value.
//!   * **D11's neighbour** — the receiver may be an enum as readily as
//!     a struct, because a method is a method wherever it was declared
//!     (docs/ENUMS.md D7).
//!
//! The refusals — a writing method bound, a resource or fresh receiver
//! bound, `==` on a function value, a function value at a worker
//! boundary, a shape that does not fit — live in `errors_spec.zig` with
//! every other diagnostic, because a program that does not compile has
//! no engine to disagree about.

const std = @import("std");
const agree = @import("agree.zig");

// ---------------------------------------------------------------------------
// The bind itself (D1, D2)
// ---------------------------------------------------------------------------

test "a method bound to its receiver lands where a function type is expected" {
    try agree.prints(
        \\struct Scale:
        \\    factor: i64
        \\
        \\    func times(n: i64) -> i64:
        \\        return n * self.factor
        \\
        \\func apply(n: i64, f: func(i64) -> i64) -> i64:
        \\    return f(n)
        \\
        \\func main():
        \\    let doubling = Scale(factor = 2)
        \\    let tripling = Scale(factor = 3)
        \\    print(str(apply(21, doubling.times)))
        \\    print(str(apply(21, tripling.times)))
        \\
    , "42\n63\n");
}

test "the written type drops the receiver's parameter and keeps every other" {
    try agree.prints(
        \\struct Between:
        \\    low: i64
        \\    high: i64
        \\
        \\    func holds(n: i64, slack: i64) -> bool:
        \\        return n >= self.low - slack and n <= self.high + slack
        \\
        \\func count(xs: list[i64], keep: func(i64, i64) -> bool, slack: i64) -> i64:
        \\    var kept = 0
        \\    for x in xs:
        \\        if keep(x, slack):
        \\            kept = kept + 1
        \\    return kept
        \\
        \\func main():
        \\    let window = Between(low = 3, high = 6)
        \\    var xs = list[i64]()
        \\    xs.append(1)
        \\    xs.append(4)
        \\    xs.append(8)
        \\    print(str(count(xs, window.holds, 0)))
        \\    print(str(count(xs, window.holds, 2)))
        \\
    , "1\n3\n");
}

test "a bind lands on a let of function type and is called through the binding" {
    try agree.prints(
        \\struct Greeter:
        \\    greeting: str
        \\
        \\    func to(name: str) -> str:
        \\        return self.greeting + ", " + name
        \\
        \\func main():
        \\    let polite = Greeter(greeting = "Good day")
        \\    let hello: func(str) -> str = polite.to
        \\    print(hello("Ada"))
        \\    print(hello("Grace"))
        \\
    , "Good day, Ada\nGood day, Grace\n");
}

test "a bound value is answered by a function and called by its caller" {
    try agree.prints(
        \\struct Offset:
        \\    by: i64
        \\
        \\    func shift(n: i64) -> i64:
        \\        return n + self.by
        \\
        \\func shifter(by: i64) -> func(i64) -> i64:
        \\    let made = Offset(by = by)
        \\    return made.shift
        \\
        \\func main():
        \\    let up = shifter(10)
        \\    let down = shifter(-10)
        \\    print(str(up(1)))
        \\    print(str(down(1)))
        \\
    , "11\n-9\n");
}

test "an enum receiver binds exactly as a struct receiver does" {
    try agree.prints(
        \\enum Step(u8):
        \\    one = 1
        \\    ten = 10
        \\
        \\    func from(n: i64) -> i64:
        \\        return n + i64(i32(self))
        \\
        \\func apply(n: i64, f: func(i64) -> i64) -> i64:
        \\    return f(n)
        \\
        \\func main():
        \\    print(str(apply(5, Step.one.from)))
        \\    print(str(apply(5, Step.ten.from)))
        \\
    , "6\n15\n");
}

// ---------------------------------------------------------------------------
// The receiver is copied in (D3)
// ---------------------------------------------------------------------------

test "the bound value carries its own receiver: writing the original misses it" {
    try agree.prints(
        \\struct Scale:
        \\    factor: i64
        \\
        \\    func times(n: i64) -> i64:
        \\        return n * self.factor
        \\
        \\func main():
        \\    var scale = Scale(factor = 2)
        \\    let doubling: func(i64) -> i64 = scale.times
        \\    scale.factor = 100
        \\    print(str(doubling(3)))
        \\    print(str(scale.times(3)))
        \\
    , "6\n300\n");
}

test "a receiver holding text is copied into the value and both are released" {
    try agree.prints(
        \\struct Label:
        \\    text: str
        \\
        \\    func of(n: i64) -> str:
        \\        return self.text + str(n)
        \\
        \\func main():
        \\    var made = ""
        \\    var index = 0
        \\    while index < 3:
        \\        made = made + str(index)
        \\        index = index + 1
        \\    let tag = Label(text = made)
        \\    let name: func(i64) -> str = tag.of
        \\    print(name(7))
        \\    print(name(8))
        \\
    , "0127\n0128\n");
}

test "a bound value copies freely into a parameter, a local and back out" {
    try agree.prints(
        \\struct Scale:
        \\    factor: i64
        \\
        \\    func times(n: i64) -> i64:
        \\        return n * self.factor
        \\
        \\func through(f: func(i64) -> i64) -> func(i64) -> i64:
        \\    let kept = f
        \\    return kept
        \\
        \\func main():
        \\    let doubling = Scale(factor = 2)
        \\    let first: func(i64) -> i64 = doubling.times
        \\    let second = through(first)
        \\    let third = through(second)
        \\    print(str(first(1)))
        \\    print(str(second(2)))
        \\    print(str(third(3)))
        \\
    , "2\n4\n6\n");
}

// ---------------------------------------------------------------------------
// The proving customer (docs/FUNCTIONS.md D6)
// ---------------------------------------------------------------------------

test "a bound comparator sorts by state the comparator carries" {
    try agree.prints(
        \\import std.lists
        \\
        \\struct Nearest:
        \\    origin: i64
        \\
        \\    func before(a: i64, b: i64) -> bool:
        \\        return abs(a - self.origin) < abs(b - self.origin)
        \\
        \\func main():
        \\    let near = Nearest(origin = 10)
        \\    var xs = list[i64]()
        \\    xs.append(1)
        \\    xs.append(14)
        \\    xs.append(9)
        \\    xs.append(30)
        \\    xs.sort_by(near.before)
        \\    for x in xs:
        \\        print(str(x))
        \\
    , "9\n14\n1\n30\n");
}

test "two binds of one method with different receivers sort differently" {
    try agree.prints(
        \\import std.lists
        \\
        \\struct Nearest:
        \\    origin: i64
        \\
        \\    func before(a: i64, b: i64) -> bool:
        \\        return abs(a - self.origin) < abs(b - self.origin)
        \\
        \\func main():
        \\    var xs = list[i64]()
        \\    xs.append(1)
        \\    xs.append(14)
        \\    xs.append(9)
        \\    let low = Nearest(origin = 0)
        \\    xs.sort_by(low.before)
        \\    print(str(xs[0]))
        \\    let high = Nearest(origin = 20)
        \\    xs.sort_by(high.before)
        \\    print(str(xs[0]))
        \\
    , "1\n14\n");
}

// ---------------------------------------------------------------------------
// What a bound value says about itself (D6)
// ---------------------------------------------------------------------------

test "str of a bound value is the method's qualified name" {
    try agree.prints(
        \\struct Scale:
        \\    factor: i64
        \\
        \\    func times(n: i64) -> i64:
        \\        return n * self.factor
        \\
        \\func main():
        \\    let doubling = Scale(factor = 2)
        \\    let f: func(i64) -> i64 = doubling.times
        \\    print(str(f))
        \\
    , "Scale.times\n");
}

// ---------------------------------------------------------------------------
// A carrying receiver is retained (D4, as amended)
// ---------------------------------------------------------------------------

test "a bind of a carrying receiver aliases the receiver's graph" {
    try agree.prints(
        \\struct Bag:
        \\    items: list[i64]
        \\
        \\    func at(i: i64) -> i64:
        \\        return self.items[i]
        \\
        \\func main():
        \\    var bag = Bag(items = [7, 8])
        \\    let read: func(i64) -> i64 = bag.at
        \\    print(str(read(0)))
        \\    bag.items.append(99)
        \\    print(str(read(2)))
        \\
    , "7\n99\n");
}

test "a carrying receiver needs no source verb, and the census is zero" {
    try agree.prints(
        \\struct Bag:
        \\    label: str
        \\    items: list[i64]
        \\
        \\    func total() -> i64:
        \\        var sum: i64 = 0
        \\        for item in self.items:
        \\            sum = sum + item
        \\        return sum
        \\
        \\func main():
        \\    var bag = Bag(label = "counts", items = [1, 2, 3])
        \\    let sum: func() -> i64 = bag.total
        \\    print(bag.label)
        \\    print(str(sum()))
        \\
    , "counts\n6\n");
}

test "a carrying receiver outlives the scope that created it" {
    try agree.prints(
        \\struct Bag:
        \\    items: list[i64]
        \\
        \\    func at(i: i64) -> i64:
        \\        return self.items[i]
        \\
        \\func reader() -> func(i64) -> i64:
        \\    let bag = Bag(items = [7, 8])
        \\    return bag.at
        \\
        \\func main():
        \\    let read = reader()
        \\    print(str(read(0)))
        \\    print(str(read(1)))
        \\
    , "7\n8\n");
}

test "a bound method takes a union task and callback graph through another struct" {
    // The value-only receiver is safe to store in Runner.  The resource
    // graph instead crosses the function-value boundary as an explicit
    // `give` argument, so the bound value never becomes a second owner.
    try agree.prints(
        \\union Job:
        \\    idle
        \\    running(task: task[i64])
        \\
        \\struct Packet:
        \\    job: Job
        \\    values: list[i64]
        \\    callback: (func(i64) -> i64)?
        \\
        \\struct Scorer:
        \\    factor: i64
        \\
        \\    func score(packet: Packet, value: i64) -> i64:
        \\        var answer: i64 = 0
        \\        match packet.job:
        \\            idle:
        \\                answer = 0
        \\            running(task):
        \\                answer = task.wait()
        \\        let chosen = packet.callback else identity
        \\        return chosen((answer + value + len(packet.values)) * self.factor)
        \\
        \\struct Runner:
        \\    operation: (func(Packet, i64) -> i64)?
        \\
        \\    func execute(packet: Packet, value: i64) -> i64:
        \\        let chosen = self.operation else fallback
        \\        return chosen(packet, value)
        \\
        \\func identity(value: i64) -> i64:
        \\    return value
        \\
        \\func produce() -> i64:
        \\    return 7
        \\
        \\func triple(value: i64) -> i64:
        \\    return value * 3
        \\
        \\func fallback(packet: Packet, value: i64) -> i64:
        \\    return value
        \\
        \\func main():
        \\    let scorer = Scorer(factor = 1)
        \\    let runner = Runner(operation = scorer.score)
        \\    let packet = Packet(
        \\        job = Job.running(task = spawn produce()),
        \\        values = [10, 20, 30],
        \\        callback = triple,
        \\    )
        \\    print(str(runner.execute(packet, 0)))
        \\
    , "30\n");
}

test "a function field resolves give through a later resource-bearing struct" {
    // Runner is deliberately declared before Packet.  The function type
    // in its field is resolved while Packet still has no collected fields;
    // ownership must wait for the shape pass rather than inspecting a
    // declaration-order-dependent partial layout.
    try agree.prints(
        \\struct Runner:
        \\    operation: (func(Packet) -> i64)?
        \\
        \\struct Packet:
        \\    values: list[i64]
        \\
        \\func count(packet: Packet) -> i64:
        \\    return len(packet.values)
        \\
        \\func main():
        \\    let runner = Runner(operation = count)
        \\    let packet = Packet(values = [1, 2, 3])
        \\    let chosen = runner.operation else count
        \\    print(str(chosen(packet)))
        \\
    , "3\n");
}

// ---------------------------------------------------------------------------
// Union member constructors are function values (D11)
// ---------------------------------------------------------------------------

test "a union member constructor lands where a function type is expected" {
    try agree.prints(
        \\union Msg:
        \\    quit
        \\    query_changed(query: str)
        \\    resized(width: i64, height: i64)
        \\
        \\func describe(m: Msg) -> str:
        \\    match m:
        \\        quit:
        \\            return "quit"
        \\        query_changed(query):
        \\            return "query " + query
        \\        resized(width, height):
        \\            return "resized " + str(width) + "x" + str(height)
        \\
        \\func route(make: func(str) -> Msg, text: str) -> str:
        \\    return describe(make(text))
        \\
        \\func main():
        \\    print(route(Msg.query_changed, "abc"))
        \\    let make: func(i64, i64) -> Msg = Msg.resized
        \\    print(describe(make(3, 4)))
        \\
    , "query abc\nresized 3x4\n");
}

test "a payload-less member stays a value, not a function" {
    try agree.prints(
        \\union Msg:
        \\    quit
        \\    query_changed(query: str)
        \\
        \\func describe(m: Msg) -> str:
        \\    match m:
        \\        quit:
        \\            return "quit"
        \\        query_changed(query):
        \\            return query
        \\
        \\func main():
        \\    let bare = Msg.quit
        \\    print(describe(bare))
        \\
    , "quit\n");
}

test "a carrying payload takes give through the constructor value, as its construction does" {
    try agree.prints(
        \\union Item:
        \\    empty
        \\    numbers(values: list[i64])
        \\
        \\func count(m: Item) -> i64:
        \\    match m:
        \\        empty:
        \\            return 0
        \\        numbers(values):
        \\            return len(values)
        \\
        \\func build(make: func(list[i64]) -> Item) -> i64:
        \\    var xs: list[i64] = [1, 2, 3]
        \\    return count(make(xs))
        \\
        \\func main():
        \\    print(str(build(Item.numbers)))
        \\
    , "3\n");
}

// ---------------------------------------------------------------------------
// A bind is not the only thing a function type holds
// ---------------------------------------------------------------------------

test "a plain function, a lambda and a bind fill one function-typed place" {
    try agree.prints(
        \\struct Scale:
        \\    factor: i64
        \\
        \\    func times(n: i64) -> i64:
        \\        return n * self.factor
        \\
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func apply(n: i64, f: func(i64) -> i64) -> i64:
        \\    return f(n)
        \\
        \\func main():
        \\    let doubling = Scale(factor = 2)
        \\    print(str(apply(5, twice)))
        \\    print(str(apply(5, (n) -> n * 2)))
        \\    print(str(apply(5, doubling.times)))
        \\
    , "10\n10\n10\n");
}

// ---------------------------------------------------------------------------
// The storable form: `(func(...) -> R)?` (D7)
// ---------------------------------------------------------------------------
//
// A slot exists before anything fills it, and a function value has no
// zero — every value of the type names a function, and an empty slot
// names none.  So the storable shape is the optional, whose zero is the
// absence `T?` already means, and reaching the value takes the
// narrowing or the `else` any other optional takes.

test "a function value lives in a struct field and is called through narrowing" {
    try agree.prints(
        \\struct Button:
        \\    label: str
        \\    on_click: (func(i64) -> i64)?
        \\
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func main():
        \\    let wired = Button(label = "double", on_click = twice)
        \\    let bare = Button(label = "plain", on_click = none)
        \\    for held in [wired, bare]:
        \\        let action = held.on_click
        \\        if action != none:
        \\            print(held.label + " " + str(action(21)))
        \\        else:
        \\            print(held.label + " none")
        \\
    , "double 42\nplain none\n");
}

test "a function value lives in a list element and is called through else" {
    try agree.prints(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func negate(n: i64) -> i64:
        \\    return 0 - n
        \\
        \\func same(n: i64) -> i64:
        \\    return n
        \\
        \\func main():
        \\    var steps = list[(func(i64) -> i64)?]()
        \\    steps.append(twice)
        \\    steps.append(none)
        \\    steps.append(negate)
        \\    var n: i64 = 3
        \\    for step in steps:
        \\        let run = step else same
        \\        n = run(n)
        \\    print(str(n))
        \\
    , "-6\n");
}

test "a map value is written bare, and get carries the absence" {
    // **The one slot no container creates.**  A map value exists
    // because a store created it, and `get` already answers `V?` — so the
    // function type is written bare there and the optional D7 asks for
    // is the missing key.  Writing the `?` as well would make `get`
    // answer a `V??`, which has no representation.
    try agree.prints(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func main():
        \\    var actions = map[str, func(i64) -> i64]()
        \\    actions["double"] = twice
        \\    let found = actions.get("double")
        \\    if found != none:
        \\        print(str(found(4)))
        \\    print(str(actions.get("missing") == none))
        \\
    , "8\ntrue\n");
}

test "a function value lives in an array cell, absent until it is filled" {
    try agree.prints(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func main():
        \\    var cells = array[(func(i64) -> i64)?](2)
        \\    print(str(cells[0] == none))
        \\    cells[1] = twice
        \\    let second = cells[1]
        \\    if second != none:
        \\        print(str(second(5)))
        \\
    , "true\n10\n");
}

test "absence is the zero of a slot declared before it is filled" {
    try agree.prints(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\struct Row:
        \\    action: (func(i64) -> i64)?
        \\
        \\func main():
        \\    var slot: (func(i64) -> i64)?
        \\    print(str(slot == none))
        \\    slot = twice
        \\    print(str(slot(3)))
        \\    var row: Row
        \\    print(str(row.action == none))
        \\
    , "true\n6\ntrue\n");
}

test "a bound method is stored in a field and called out of it" {
    try agree.prints(
        \\struct Scale:
        \\    factor: i64
        \\
        \\    func times(n: i64) -> i64:
        \\        return n * self.factor
        \\
        \\struct Step:
        \\    name: str
        \\    action: (func(i64) -> i64)?
        \\
        \\func main():
        \\    let three = Scale(factor = 3)
        \\    let step = Step(name = "triple", action = three.times)
        \\    let action = step.action
        \\    if action != none:
        \\        print(step.name + " " + str(action(7)))
        \\
    , "triple 21\n");
}

test "a stored function value is released with what holds it" {
    // The value owns its run and any receiver references.  The census is
    // zero when the list and the receiver's other owner both die.
    try agree.prints(
        \\struct Scale:
        \\    factor: i64
        \\
        \\    func times(n: i64) -> i64:
        \\        return n * self.factor
        \\
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func main():
        \\    let three = Scale(factor = 3)
        \\    var steps = list[(func(i64) -> i64)?]()
        \\    steps.append(twice)
        \\    steps.append(three.times)
        \\    steps.append(none)
        \\    var total: i64 = 0
        \\    for step in steps:
        \\        let run = step else twice
        \\        total = total + run(1)
        \\    print(str(total))
        \\
    , "7\n");
}

test "a lambda stored in a slot is a function value like any other" {
    try agree.prints(
        \\struct Row:
        \\    action: (func(i64) -> i64)?
        \\
        \\func main():
        \\    let row = Row(action = (n) -> n + 1)
        \\    let action = row.action
        \\    if action != none:
        \\        print(str(action(41)))
        \\
    , "42\n");
}

// ---------------------------------------------------------------------------
// The landing place, at every depth
// ---------------------------------------------------------------------------
//
// **The landing place is what types a function value** (FUNCTIONS D2),
// so D7's storable slots are only reachable where the place is *known*.
// A written path names its own leaf — a field names its type and a
// container names its element — so the leaf of `self.pane.render` is as
// well written down as the leaf of `pane.render`, and the depth of a
// slot is not something the language has an opinion about.
//
// These prove the whole path, not the prefix: a store through a field,
// through `self`, through a list, an array and a map index, and a call
// back out of the slot afterwards — because typechecking a store proves
// nothing about what it stored.

test "a function value lands on a field two steps in, through a local and through self" {
    try agree.prints(
        \\func plain(index: i64) -> str:
        \\    return "plain " + str(index)
        \\
        \\struct Rows:
        \\    render: (func(i64) -> str)? = none
        \\
        \\struct App:
        \\    rows: Rows
        \\
        \\    func wire():
        \\        self.rows.render = plain
        \\
        \\    func read(index: i64) -> str:
        \\        let action = self.rows.render
        \\        if action != none:
        \\            return action(index)
        \\        return "none"
        \\
        \\func main():
        \\    var written = App(rows = Rows())
        \\    written.rows.render = plain
        \\    print(written.read(1))
        \\    var wired = App(rows = Rows())
        \\    wired.wire()
        \\    print(wired.read(2))
        \\    print(App(rows = Rows()).read(3))
        \\
    , "plain 1\nplain 2\nnone\n");
}

test "a function value lands on the field of an element, in a list, an array and a map" {
    // The step in front of the leaf is an *index* here, which is the
    // shape that has no operand of its own to ask: the container is
    // named by the path, not by a value already lowered.  All three
    // spellings of a function value are stored through one, and each is
    // read back out through the narrowing D7 asks for.
    try agree.prints(
        \\struct Names:
        \\    items: list[str]
        \\
        \\    func at(index: i64) -> str:
        \\        return self.items[index]
        \\
        \\struct Cell:
        \\    render: (func(i64) -> str)? = none
        \\
        \\func plain(index: i64) -> str:
        \\    return "plain " + str(index)
        \\
        \\func main():
        \\    var names = Names(items = list[str]())
        \\    names.items.append("zero")
        \\    names.items.append("one")
        \\    var rows = list[Cell]()
        \\    rows.append(Cell())
        \\    rows[0].render = (n) -> "lambda " + str(n)
        \\    var grid = array[Cell](2, 2)
        \\    grid[1, 1].render = names.at
        \\    var by_name = map[str, Cell]()
        \\    by_name["head"] = Cell()
        \\    by_name["head"].render = plain
        \\    let listed = rows[0].render
        \\    if listed != none:
        \\        print(listed(4))
        \\    let celled = grid[1, 1].render
        \\    if celled != none:
        \\        print(celled(1))
        \\    let keyed = by_name["head"].render
        \\    if keyed != none:
        \\        print(keyed(6))
        \\
    , "lambda 4\none\nplain 6\n");
}

test "a nested place takes a union constructor, a match arm, a guarded call and the bare none" {
    // Every other thing that has no type until it lands: a member
    // constructor as a value (D11), a `catch` fallback, and `none`
    // itself — which has no type at all and takes the leaf's.  The
    // store inside the `match` arm is the same statement in a narrower
    // scope, and proves the landing is a property of the path rather
    // than of where the statement stands.
    try agree.prints(
        \\union Msg:
        \\    quit
        \\    query(text: str)
        \\
        \\func plain(index: i64) -> str:
        \\    return "plain " + str(index)
        \\
        \\func chosen(flag: bool) -> (func(i64) -> str)?!:
        \\    if flag:
        \\        return plain
        \\    error("no")
        \\
        \\struct Rows:
        \\    make: (func(str) -> Msg)? = none
        \\    render: (func(i64) -> str)? = none
        \\
        \\struct App:
        \\    rows: Rows
        \\
        \\func main():
        \\    var app = App(rows = Rows())
        \\    app.rows.make = Msg.query
        \\    let build = app.rows.make
        \\    if build != none:
        \\        match build("hello"):
        \\            quit:
        \\                print("quit")
        \\            query(text):
        \\                print("query " + text)
        \\    match Msg.quit:
        \\        quit:
        \\            app.rows.render = plain
        \\        query(text):
        \\            print(text)
        \\    let armed = app.rows.render
        \\    if armed != none:
        \\        print(armed(1))
        \\    app.rows.render = none
        \\    print(str(app.rows.render == none))
        \\    app.rows.render = chosen(false) catch plain
        \\    let caught = app.rows.render
        \\    if caught != none:
        \\        print(caught(2))
        \\
    , "query hello\nplain 1\ntrue\nplain 2\n");
}

test "a union payload composes with a bound method and a stored callback" {
    // This is the deliberately cross-feature case: the union owns a
    // list of value structs, a match arm reads one of those structs,
    // its method becomes an owning function value, and the enclosing
    // value carries a second optional function value.  No layer gets
    // to treat one of those shapes as a special case.
    try agree.prints(
        \\struct Item:
        \\    prefix: str
        \\    scale: i64
        \\    func render(value: i64) -> str:
        \\        return self.prefix + str(value * self.scale)
        \\
        \\union Work:
        \\    empty
        \\    batch(items: list[Item])
        \\
        \\struct Plan:
        \\    work: Work
        \\    finish: (func(i64) -> str)? = none
        \\
        \\func suffix(value: i64) -> str:
        \\    return "!" + str(value)
        \\
        \\func evaluate(plan: Plan) -> str:
        \\    let finish = plan.finish
        \\    match plan.work:
        \\        empty:
        \\            return "empty"
        \\        batch(items):
        \\            let render: func(i64) -> str = items[0].render
        \\            if finish != none:
        \\                return render(4) + finish(5)
        \\            return render(4)
        \\
        \\func main():
        \\    var items = list[Item]()
        \\    items.append(Item(prefix = "item", scale = 2))
        \\    let plan = Plan(work = Work.batch(items = items), finish = suffix)
        \\    print(evaluate(plan))
        \\
    , "item8!5\n");
}

test "a nested place under try lands what the call answers" {
    try agree.prints(
        \\func plain(index: i64) -> str:
        \\    return "plain " + str(index)
        \\
        \\func chosen(flag: bool) -> (func(i64) -> str)?!:
        \\    if flag:
        \\        return plain
        \\    error("no")
        \\
        \\struct Rows:
        \\    render: (func(i64) -> str)? = none
        \\
        \\struct App:
        \\    rows: Rows
        \\
        \\func main() -> !:
        \\    var app = App(rows = Rows())
        \\    app.rows.render = try chosen(true)
        \\    let held = app.rows.render
        \\    if held != none:
        \\        print(held(5))
        \\
    , "plain 5\n");
}

test "a builtin method's parameter is a landing place, whatever the receiver named" {
    // A builtin method's parameter is written down in a table rather
    // than in source, and it lands its argument exactly as a declared
    // parameter does: the type comes from the *receiver*, which is
    // operand zero of the same batch, so `landsOn` answers it after
    // that one is lowered and before this one is.
    //
    // All three spellings of a function value go in through one — a
    // plain name, a lambda and a bind — and each is called back out,
    // because typechecking a store proves nothing about what it
    // stored.  The two other things that have no type until they land
    // ride along: a bare `none`, and a number at the width the
    // element names rather than the width it would default to.
    try agree.prints(
        \\import std.lists
        \\
        \\struct Row:
        \\    weight: i64
        \\
        \\    func heavier(a: i64, b: i64) -> bool:
        \\        return a * self.weight > b * self.weight
        \\
        \\func plain(index: i64) -> str:
        \\    return "plain " + str(index)
        \\
        \\func main():
        \\    var steps = list[(func(i64) -> str)?]()
        \\    steps.append(plain)
        \\    steps.insert(0, (n) -> "lambda " + str(n))
        \\    steps.append(none)
        \\    for step in steps:
        \\        if step != none:
        \\            print(step(1))
        \\        else:
        \\            print("none")
        \\    var cells = array[(func(i64) -> str)?](2)
        \\    cells.fill(plain)
        \\    let filled = cells[1]
        \\    if filled != none:
        \\        print(filled(2))
        \\    let ordering = Row(weight = 1)
        \\    var numbers = list[i64]()
        \\    numbers.append(1)
        \\    numbers.append(3)
        \\    numbers.append(2)
        \\    numbers.sort_by(ordering.heavier)
        \\    print(str(numbers[0]) + str(numbers[1]) + str(numbers[2]))
        \\    var small = list[u8]()
        \\    small.append(200)
        \\    small.insert(0, 255)
        \\    print(str(small[0]) + " " + str(small[1]))
        \\
    , "lambda 1\nplain 1\nnone\nplain 2\n321\n255 200\n");
}

test "the leaf of a nested place names the width its value is read at" {
    // **Not a function-value rule.**  What a nested place had been
    // missing was the landing itself, and a number is the other thing
    // that has no type until it lands (docs/TYPES.md §1) — so `200`
    // reaching a `u8` three steps in reads as a `u8`, exactly as it
    // does one step in, rather than reading as an `i32` and then being
    // refused for not narrowing.  A compound assignment combines at the
    // same leaf.
    try agree.prints(
        \\struct Inner:
        \\    small: u8 = 0
        \\    wide: i64 = 0
        \\    ratio: f64 = 0.0
        \\
        \\struct Outer:
        \\    inner: Inner
        \\
        \\func main():
        \\    var outer = Outer(inner = Inner())
        \\    outer.inner.small = 200
        \\    outer.inner.small += 1
        \\    outer.inner.wide = 3000000000
        \\    outer.inner.ratio = 3
        \\    print(str(outer.inner.small))
        \\    print(str(outer.inner.wide))
        \\    print(str(outer.inner.ratio))
        \\
    , "201\n3000000000\n3\n");
}

// ---------------------------------------------------------------------------
// Where the comparison refusal stops (D6, D7)
// ---------------------------------------------------------------------------
//
// D6's refusal is about what a comparison *reaches*, and a refusal that
// reaches too far is as wrong as one that reaches too little.  These
// three facts pin the frontier: `==` descends a struct's field run and
// stops dead at an object handle, because object equality is identity
// and never reads what is inside.  The corresponding refusals are in
// `errors_spec.zig`.

test "a struct of ordinary values still compares, field for field" {
    try agree.prints(
        \\struct Point:
        \\    x: i64
        \\    y: i64
        \\
        \\struct Line:
        \\    a: Point
        \\    b: Point
        \\    label: str
        \\
        \\func main():
        \\    let one = Line(a = Point(x = 1, y = 2), b = Point(x = 3, y = 4), label = "l")
        \\    let same = Line(a = Point(x = 1, y = 2), b = Point(x = 3, y = 4), label = "l")
        \\    let other = Line(a = Point(x = 1, y = 2), b = Point(x = 3, y = 5), label = "l")
        \\    print(str(one == same))
        \\    print(str(one == other))
        \\    print(str(one != other))
        \\
    , "true\nfalse\ntrue\n");
}

test "a struct holding a container of function values compares by handle, and is not refused" {
    // **The frontier, stated as a program.**  `Panel` reaches a
    // function value through its list, and `==` never looks: a list
    // compares as the object it is, so two panels naming one list are
    // equal and two naming different lists are not, whatever the
    // elements hold.  Asking `shapes.carries` here — the walk the
    // worker boundary uses, which goes through a container because a
    // `give` moves the whole graph — would refuse this program for a
    // comparison it does not make.
    try agree.prints(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\struct Button:
        \\    on_click: (func(i64) -> i64)?
        \\
        \\struct Panel:
        \\    buttons: list[Button]
        \\
        \\func main():
        \\    var buttons = list[Button]()
        \\    buttons.append(Button(on_click = twice))
        \\    let panel = Panel(buttons = buttons)
        \\    let same_panel = panel
        \\    print(str(panel == same_panel))
        \\    var others = list[Button]()
        \\    others.append(Button(on_click = twice))
        \\    let second = Panel(buttons = others)
        \\    print(str(panel == second))
        \\
    , "true\nfalse\n");
}

test "searching a container of values that do compare is untouched" {
    try agree.prints(
        \\struct Point:
        \\    x: i64
        \\    y: i64
        \\
        \\func main():
        \\    var numbers = list[i64]()
        \\    numbers.append(3)
        \\    numbers.append(7)
        \\    print(str(numbers.find(7) else -1))
        \\    print(str(numbers.contains(4)))
        \\    var names = list[str]()
        \\    names.append("a")
        \\    print(str(names.contains("a")))
        \\    var points = list[Point]()
        \\    points.append(Point(x = 1, y = 2))
        \\    print(str(points.contains(Point(x = 1, y = 2))))
        \\    print(str(points.find(Point(x = 9, y = 9)) else -1))
        \\
    , "1\nfalse\ntrue\ntrue\n-1\n");
}

test "values() of an ordinary map still answers the list of them" {
    // The contrast case for D7's refusal: only a *bare function* value
    // type has no list to be put in, and every other map answers
    // `values()` exactly as it always did.
    try agree.prints(
        \\struct Point:
        \\    x: i64
        \\    y: i64
        \\
        \\func main():
        \\    var counts = map[str, i64]()
        \\    counts["a"] = 1
        \\    counts["b"] = 2
        \\    let numbers = counts.values()
        \\    print(str(len(numbers)))
        \\    var places = map[str, Point]()
        \\    places["home"] = Point(x = 1, y = 2)
        \\    let points = places.values()
        \\    print(str(points[0].x))
        \\    var handlers = map[str, func(i64) -> i64]()
        \\    print(str(len(handlers.keys())))
        \\
    , "2\n1\n0\n");
}
