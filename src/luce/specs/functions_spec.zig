//! Functions as values, as an executable specification
//! (docs/FUNCTIONS.md).
//!
//! Every fact below is proved on **both engines** — the interpreter and
//! the compiled artifact, run and compared on prints, trap code, trap
//! message, call trace frame for frame, leak census and the world each
//! left behind (`agree.zig`).  That bar is what D2 is for: a function
//! value is the *index* of the function it names, and both engines
//! dispatch through the program's function table, one holding pointers
//! and one holding functions — so a disagreement here is a bug in one
//! arm rather than a difference of pretence.
//!
//! What is proved, in the order the design states it:
//!
//!   * **S1** — a named top-level function is a value where a function
//!     type is expected, and so is a static member function and one
//!     reached through an import.
//!   * **S2** — the type is `func(T, ...) -> R`, and the shape a call
//!     through it takes is the shape the type wrote down.
//!   * **S3** — a lambda is a parenthesized parameter list, an arrow
//!     and one expression, and its parameter types come from the place
//!     it lands on.
//!   * **D2** — a lambda *is* the named case after the analyzer runs:
//!     the two spellings are the same instruction, and the same
//!     dispatch.
//!   * **D3** — function values have no equality or ordering;
//!     `string(f)` answers the function's name, and copying one costs
//!     nothing and frees nothing.
//!   * **D5** — a `give`-taking function is passable, and the call
//!     *through the value* checks the verbs exactly as a direct call
//!     does.
//!
//! The refusals — a method reference, a capture, a lambda with no
//! landing site, a block body — live in `errors_spec.zig` with every
//! other diagnostic, because a program that does not compile has no
//! engine to disagree about.

const std = @import("std");
const agree = @import("agree.zig");

// ---------------------------------------------------------------------------
// A named function is a value (S1)
// ---------------------------------------------------------------------------

test "a named function passed to a function-typed parameter is called through" {
    try agree.prints(
        \\func ascending(a: long, b: long) -> bool:
        \\    return a < b
        \\
        \\func descending(a: long, b: long) -> bool:
        \\    return a > b
        \\
        \\func pick(before: func(long, long) -> bool, a: long, b: long) -> long:
        \\    if before(a, b):
        \\        return a
        \\    return b
        \\
        \\func main():
        \\    print(string(pick(ascending, 3, 7)))
        \\    print(string(pick(descending, 3, 7)))
        \\
    , "3\n7\n");
}

test "a let of function type holds a function and calls it" {
    try agree.prints(
        \\func twice(n: long) -> long:
        \\    return n * 2
        \\
        \\func main():
        \\    let f: func(long) -> long = twice
        \\    print(string(f(21)))
        \\
    , "42\n");
}

test "a static member function is a value, and so is one from another module" {
    try agree.prints(
        \\import std.math
        \\
        \\struct Scale:
        \\    static func twice(n: long) -> long:
        \\        return n * 2
        \\
        \\func apply(f: func(long) -> long, x: long) -> long:
        \\    return f(x)
        \\
        \\func applyDouble(f: func(double) -> double, x: double) -> double:
        \\    return f(x)
        \\
        \\func main():
        \\    print(string(apply(Scale.twice, 5)))
        \\    print(string(applyDouble(math.round, 2.75)))
        \\
    , "10\n3\n");
}

test "a function value answering nothing is called as a statement" {
    try agree.prints(
        \\func shout(word: string):
        \\    print(word + "!")
        \\
        \\func twice(say: func(string), word: string):
        \\    say(word)
        \\    say(word)
        \\
        \\func main():
        \\    twice(shout, "hi")
        \\
    , "hi!\nhi!\n");
}

test "a function value takes and answers every shape a function does" {
    try agree.prints(
        \\struct Point:
        \\    x: long
        \\    y: long
        \\
        \\func flip(p: Point) -> Point:
        \\    return Point(x = p.y, y = p.x)
        \\
        \\func total(xs: list(long)) -> long:
        \\    var sum: long = 0
        \\    for n in xs:
        \\        sum = sum + n
        \\    return sum
        \\
        \\func label(n: long) -> string:
        \\    return f"n={n}"
        \\
        \\func main():
        \\    let turn: func(Point) -> Point = flip
        \\    let sum: func(list(long)) -> long = total
        \\    let say: func(long) -> string = label
        \\    let p = turn(Point(x = 1, y = 2))
        \\    print(string(p.x) + "," + string(p.y))
        \\    let xs: list(long) = [1, 2, 3]
        \\    print(string(sum(xs)))
        \\    print(say(7))
        \\
    , "2,1\n6\nn=7\n");
}

// ---------------------------------------------------------------------------
// Lambdas (S3, D2)
// ---------------------------------------------------------------------------

test "a lambda takes its parameter types from the place it lands on" {
    try agree.prints(
        \\func pick(before: func(long, long) -> bool, a: long, b: long) -> long:
        \\    if before(a, b):
        \\        return a
        \\    return b
        \\
        \\func main():
        \\    print(string(pick((a, b) -> a < b, 3, 7)))
        \\    print(string(pick((a, b) -> a > b, 3, 7)))
        \\
    , "3\n7\n");
}

test "a lambda lands on a let, and on a double it never wrote a type for" {
    try agree.prints(
        \\func main():
        \\    let half: func(double) -> double = (x) -> x / 2.0
        \\    let near: func(long) -> bool = (n) -> n < 10
        \\    print(string(half(5.0)))
        \\    print(string(near(3)))
        \\    print(string(near(30)))
        \\
    , "2.5\ntrue\nfalse\n");
}

test "a lambda with no parameters, and one answering nothing" {
    try agree.prints(
        \\func run(f: func() -> long) -> long:
        \\    return f()
        \\
        \\func each(say: func(string), word: string):
        \\    say(word)
        \\
        \\func main():
        \\    print(string(run(() -> 7)))
        \\    each((w) -> print(w + "."), "here")
        \\
    , "7\nhere.\n");
}

test "a lambda's body may name a constant and call a visible function" {
    try agree.prints(
        \\import std.math
        \\
        \\const step = 4
        \\
        \\func triple(n: long) -> long:
        \\    return n * 3
        \\
        \\func apply(f: func(long) -> long, x: long) -> long:
        \\    return f(x)
        \\
        \\func read(f: func() -> double) -> double:
        \\    return f()
        \\
        \\func apply_double(f: func(double) -> double, x: double) -> double:
        \\    return f(x)
        \\
        \\func main():
        \\    print(string(apply((n) -> n + step, 1)))
        \\    print(string(apply((n) -> triple(n) + step, 2)))
        \\    assert(read(() -> math.pi) > 3.0)
        \\    assert(apply_double((x) -> math.round(x), 2.75) == 3.0)
        \\
    , "5\n10\n");
}

test "a lambda is the named case: the two spellings run the same way" {
    try agree.prints(
        \\func ascending(a: long, b: long) -> bool:
        \\    return a < b
        \\
        \\func pick(before: func(long, long) -> bool, a: long, b: long) -> long:
        \\    if before(a, b):
        \\        return a
        \\    return b
        \\
        \\func main():
        \\    print(string(pick(ascending, 3, 7)))
        \\    print(string(pick((a, b) -> a < b, 3, 7)))
        \\
    , "3\n3\n");
}

test "a lambda nested inside a lambda's body is a function of its own" {
    try agree.prints(
        \\func apply(f: func(long) -> long, x: long) -> long:
        \\    return f(x)
        \\
        \\func twice(f: func(long) -> long, x: long) -> long:
        \\    return f(f(x))
        \\
        \\func main():
        \\    print(string(twice((n) -> apply((m) -> m + 1, n), 5)))
        \\
    , "7\n");
}

// ---------------------------------------------------------------------------
// A function value is a value (D3)
// ---------------------------------------------------------------------------

// D3's equality is one version old, and BINDING.md D6 retired it: a
// function value is the function it names *and* the receiver it may
// carry, and its type cannot say which, so `==` has no honest answer.
// The refusal lives in `errors_spec.zig`; what a program asks instead
// is the name, which is the test below.

test "the name a function value answers is what distinguishes two of them" {
    try agree.prints(
        \\func up(a: long, b: long) -> bool:
        \\    return a < b
        \\
        \\func down(a: long, b: long) -> bool:
        \\    return a > b
        \\
        \\func main():
        \\    let f: func(long, long) -> bool = up
        \\    let g: func(long, long) -> bool = up
        \\    let h: func(long, long) -> bool = down
        \\    print(string(string(f) == string(g)))
        \\    print(string(string(f) == string(h)))
        \\
    , "true\nfalse\n");
}

test "string of a function value is the function's name" {
    try agree.prints(
        \\struct Scale:
        \\    static func twice(n: long) -> long:
        \\        return n * 2
        \\
        \\func half(n: long) -> long:
        \\    return n // 2
        \\
        \\func name(f: func(long) -> long) -> string:
        \\    return string(f)
        \\
        \\func main():
        \\    print(name(half))
        \\    print(name(Scale.twice))
        \\
    , "half\nScale.twice\n");
}

test "string gives sibling lambdas distinct compiler function names" {
    try agree.prints(
        \\func main():
        \\    let twice: func(long) -> long = (n) -> n * 2
        \\    let thrice: func(long) -> long = (n) -> n * 3
        \\    print(string(string(twice) != string(thrice)))
        \\
    , "true\n");
}

test "a function value copies freely, into a local, a parameter and back out" {
    try agree.prints(
        \\func twice(n: long) -> long:
        \\    return n * 2
        \\
        \\func chosen() -> func(long) -> long:
        \\    return twice
        \\
        \\func through(f: func(long) -> long) -> func(long) -> long:
        \\    let kept = f
        \\    return kept
        \\
        \\func main():
        \\    let a = chosen()
        \\    let b = through(a)
        \\    print(string(b(4)))
        \\    print(string(string(a) == string(b)))
        \\
    , "8\ntrue\n");
}

// ---------------------------------------------------------------------------
// Ownership travels through the value (D5)
// ---------------------------------------------------------------------------

test "a give-taking function is a value, and the call through it needs the verb" {
    try agree.prints(
        \\func consume(xs: give list(long)) -> long:
        \\    var sum: long = 0
        \\    for n in xs:
        \\        sum = sum + n
        \\    return sum
        \\
        \\func run(f: func(give list(long)) -> long, xs: give list(long)) -> long:
        \\    return f(give xs)
        \\
        \\func main():
        \\    let xs: list(long) = [1, 2, 3]
        \\    print(string(run(consume, give xs)))
        \\
    , "6\n");
}

test "a borrowing function value leaves its argument with its owner" {
    try agree.prints(
        \\func total(xs: list(long)) -> long:
        \\    var sum: long = 0
        \\    for n in xs:
        \\        sum = sum + n
        \\    return sum
        \\
        \\func twice(f: func(list(long)) -> long, xs: list(long)) -> long:
        \\    return f(xs) + f(xs)
        \\
        \\func main():
        \\    let xs: list(long) = [1, 2, 3]
        \\    print(string(twice(total, xs)))
        \\    print(string(len(xs)))
        \\
    , "12\n3\n");
}

// ---------------------------------------------------------------------------
// The proving standard-library customer (D6)
// ---------------------------------------------------------------------------

test "std lists sort_by specializes for a struct and accepts a lambda" {
    try agree.ok(
        \\import std.lists
        \\
        \\struct Player:
        \\    score: long
        \\    order: long
        \\
        \\func by_score(a: Player, b: Player) -> bool:
        \\    return a.score < b.score
        \\
        \\func main():
        \\    var empty = new list(Player)
        \\    empty.sort_by(by_score)
        \\    assert(len(empty) == 0)
        \\    var one = [Player(score = 7, order = 9)]
        \\    one.sort_by(by_score)
        \\    assert(one[0].order == 9)
        \\    var players = [
        \\        Player(score = 20, order = 0),
        \\        Player(score = 10, order = 1),
        \\        Player(score = 20, order = 2),
        \\        Player(score = 30, order = 3),
        \\    ]
        \\    players.sort_by(by_score)
        \\    assert(players[0].score == 10)
        \\    assert(players[1].score == 20)
        \\    assert(players[1].order == 0)
        \\    assert(players[2].score == 20)
        \\    assert(players[2].order == 2)
        \\    assert(players[3].score == 30)
        \\    players.sort_by((a, b) -> a.score > b.score)
        \\    assert(players[0].score == 30)
        \\    assert(players[1].score == 20)
        \\    assert(players[1].order == 0)
        \\    assert(players[2].score == 20)
        \\    assert(players[2].order == 2)
        \\    assert(players[3].score == 10)
        \\    var numbers: list(long) = [3, 1, 2]
        \\    numbers.sort_by((a, b) -> a < b)
        \\    assert(numbers[0] == 1)
        \\    assert(numbers[1] == 2)
        \\    assert(numbers[2] == 3)
        \\
    );
}

test "std lists sort_by moves object elements without copying them" {
    try agree.ok(
        \\import std.lists
        \\
        \\func row_before(a: list(long), b: list(long)) -> bool:
        \\    return a[0] < b[0]
        \\
        \\func main():
        \\    var rows = new list(list(long))
        \\    rows.append([3])
        \\    rows.append([1])
        \\    rows.append([2])
        \\    rows.sort_by(row_before)
        \\    assert(rows[0][0] == 1)
        \\    assert(rows[1][0] == 2)
        \\    assert(rows[2][0] == 3)
        \\
    );
}

test "std lists sort_by moves task resources and keeps equivalent elements stable" {
    try agree.prints(
        \\import std.lists
        \\
        \\func answer(n: long) -> long:
        \\    return n
        \\
        \\func equivalent(a: task(long), b: task(long)) -> bool:
        \\    return false
        \\
        \\func main():
        \\    var tasks = new list(task(long))
        \\    tasks.append(spawn answer(1))
        \\    tasks.append(spawn answer(2))
        \\    tasks.sort_by(equivalent)
        \\    var joined: long = 0
        \\    for work in tasks:
        \\        joined = joined * 10 + work.wait()
        \\    print(string(joined))
        \\
    , "12\n");
}

// ---------------------------------------------------------------------------
// A function value is a call in flight: everything a call promises
// ---------------------------------------------------------------------------

test "a trap inside a function value's callee names the callee in the trace" {
    try agree.trap(
        \\func bad(n: long) -> long:
        \\    return n // 0
        \\
        \\func apply(f: func(long) -> long, x: long) -> long:
        \\    return f(x)
        \\
        \\func main():
        \\    var n = 1
        \\    print(string(apply(bad, n)))
        \\
    , .divide_by_zero);
}

test "recursion through a function value exhausts the same budget a call does" {
    try agree.trap(
        \\func down(f: func(long) -> long, n: long) -> long:
        \\    return f(n)
        \\
        \\func step(n: long) -> long:
        \\    return down(step, n + 1)
        \\
        \\func main():
        \\    var n = 0
        \\    print(string(down(step, n)))
        \\
    , .call_depth_exceeded);
}

test "a function value chosen by a branch dispatches to whichever was chosen" {
    try agree.prints(
        \\func up(a: long, b: long) -> bool:
        \\    return a < b
        \\
        \\func down(a: long, b: long) -> bool:
        \\    return a > b
        \\
        \\func pick(rising: bool) -> func(long, long) -> bool:
        \\    if rising:
        \\        return up
        \\    return down
        \\
        \\func main():
        \\    var which = true
        \\    var seen = 0
        \\    while seen < 2:
        \\        let f = pick(which)
        \\        print(string(f(1, 2)))
        \\        which = not which
        \\        seen = seen + 1
        \\
    , "true\nfalse\n");
}

// A function value does not cross a worker boundary (docs/BINDING.md
// D4, as amended): it borrows the receiver it may carry, a borrow
// cannot cross, and a function type cannot say whether this one
// carries anything.  Both refusals are proved in `errors_spec.zig`.
// What survives here is the fact those two tests were really about —
// a `give`-taking function called through a value moves its argument
// exactly as a direct call does (D5).

test "a give-taking function value moves its argument when called through the value" {
    try agree.prints(
        \\func consume(values: give list(long)) -> long:
        \\    var total: long = 0
        \\    for value in values:
        \\        total += value
        \\    return total
        \\
        \\func run(f: func(give list(long)) -> long, values: give list(long)) -> long:
        \\    return f(give values)
        \\
        \\func main():
        \\    var values: list(long) = [1, 2, 3, 4]
        \\    print(string(run(consume, give values)))
        \\
    , "10\n");
}

// ---------------------------------------------------------------------------
// The call suffix: a call is a postfix operator
// ---------------------------------------------------------------------------
//
// `EXPR(args)` parses wherever `EXPR[i]` does, and calls the value the
// expression answers.  The head-names-a-declaration forms — `f(x)`,
// `Struct.helper(x)`, `receiver.method(x)`, `Enum(n)` and every builtin
// — are unchanged and still take the declaration path; what is new is
// every callee that was never a name.  The refusals, an absent callee
// above all, live in `errors_spec.zig`.

test "the answer of a call is called in place" {
    try agree.prints(
        \\func plain(n: long) -> string:
        \\    return "n=" + string(n)
        \\
        \\func chooser() -> func(long) -> string:
        \\    return plain
        \\
        \\func main():
        \\    print(chooser()(5))
        \\
    , "n=5\n");
}

test "a chain of calls dispatches left to right" {
    try agree.prints(
        \\func add(n: long) -> string:
        \\    return string(n)
        \\
        \\func pick() -> func(long) -> string:
        \\    return add
        \\
        \\func picker() -> func() -> func(long) -> string:
        \\    return pick
        \\
        \\func main():
        \\    print(picker()()(7))
        \\
    , "7\n");
}

test "a bare map value is called where it is read" {
    // A map value is the one container slot written bare
    // (docs/BINDING.md D7), so `m[k]` answers a function value with
    // nothing to narrow and the call suffix applies to it directly.
    try agree.prints(
        \\func twice(n: long) -> long:
        \\    return n * 2
        \\
        \\func negate(n: long) -> long:
        \\    return 0 - n
        \\
        \\func main():
        \\    var actions = new map(string, func(long) -> long)
        \\    actions["double"] = twice
        \\    actions["negate"] = negate
        \\    print(string(actions["double"](21)))
        \\    print(string(actions["negate"](21)))
        \\
    , "42\n-21\n");
}

test "a stored bound method is called out of the map that holds it" {
    // The receiver rides in the value (docs/BINDING.md D3), so calling
    // it in place calls it on the state it carries.
    try agree.prints(
        \\struct Counter:
        \\    step: long
        \\
        \\    func times(n: long) -> long:
        \\        return n * self.step
        \\
        \\func main():
        \\    let two = Counter(step = 2)
        \\    let three = Counter(step = 3)
        \\    var scales = new map(string, func(long) -> long)
        \\    scales["two"] = two.times
        \\    scales["three"] = three.times
        \\    print(string(scales["two"](10)))
        \\    print(string(scales["three"](10)))
        \\
    , "20\n30\n");
}

test "a bound method carries a union callback into another struct's function" {
    // This is the composition seam where three representations meet: the
    // bound method borrows its Envelope receiver, the receiver contains a
    // tagged union with an optional function value, and Runner accepts that
    // value through an ordinary function-typed parameter.
    try agree.prints(
        \\union Job:
        \\    action(run: (func(long) -> long)?, value: long)
        \\
        \\struct Runner:
        \\    bias: long
        \\
        \\    func apply(f: func(long) -> long, value: long) -> long:
        \\        return f(value + self.bias)
        \\
        \\struct Envelope:
        \\    job: Job
        \\    runner: Runner
        \\
        \\    func run() -> long:
        \\        match self.job:
        \\            action(run, value):
        \\                let chosen = run else identity
        \\                return self.runner.apply(chosen, value)
        \\
        \\func twice(n: long) -> long:
        \\    return n * 2
        \\
        \\func identity(n: long) -> long:
        \\    return n
        \\
        \\func main():
        \\    let with_callback = Envelope(
        \\        job = Job.action(run = twice, value = 5),
        \\        runner = Runner(bias = 10),
        \\    )
        \\    let without_callback = Envelope(
        \\        job = Job.action(run = none, value = 5),
        \\        runner = Runner(bias = 10),
        \\    )
        \\    let first: func() -> long = with_callback.run
        \\    let second: func() -> long = without_callback.run
        \\    print(string(first()))
        \\    print(string(second()))
        \\
    , "30\n15\n");
}

test "a field narrowed into a local is still called through the local" {
    // The path `packages/termui-0.1.0/rows.luc` takes, and the one a
    // storable function value will always take: a field cannot be
    // narrowed, so the value is bound first.
    try agree.prints(
        \\struct Rows:
        \\    render: (func(long) -> string)?
        \\
        \\func label(index: long) -> string:
        \\    return "row " + string(index)
        \\
        \\func main():
        \\    let rows = Rows(render = label)
        \\    let provider = rows.render
        \\    if provider != none:
        \\        print(provider(3))
        \\    let empty = Rows(render = none)
        \\    let missing = empty.render
        \\    print(string(missing == none))
        \\
    , "row 3\ntrue\n");
}

test "a give travels through a call suffix exactly as through a name" {
    // D5's sentence, at a callee that is not a name: the verbs are the
    // signature's business and the callee's spelling changes nothing.
    try agree.prints(
        \\func consume(values: give list(long)) -> long:
        \\    var total: long = 0
        \\    for value in values:
        \\        total += value
        \\    return total
        \\
        \\func pick() -> func(give list(long)) -> long:
        \\    return consume
        \\
        \\func main():
        \\    var values: list(long) = [1, 2, 3, 4]
        \\    print(string(pick()(give values)))
        \\
    , "10\n");
}

test "a call suffix answering nothing stands as a statement" {
    try agree.prints(
        \\func shout(n: long):
        \\    print("n=" + string(n))
        \\
        \\func pick() -> func(long):
        \\    return shout
        \\
        \\func main():
        \\    pick()(1)
        \\    pick()(2)
        \\
    , "n=1\nn=2\n");
}

test "the callee runs before the arguments" {
    // A call suffix is an expression like any other and reads left to
    // right: what stands in front of the parentheses is evaluated
    // first, then each argument in turn.
    try agree.prints(
        \\func note(text: string) -> long:
        \\    print(text)
        \\    return 1
        \\
        \\func sum(a: long, b: long) -> long:
        \\    return a + b
        \\
        \\func chooser() -> func(long, long) -> long:
        \\    print("callee")
        \\    return sum
        \\
        \\func main():
        \\    print(string(chooser()(note("first"), note("second"))))
        \\
    , "callee\nfirst\nsecond\n2\n");
}

test "an argument that opens a block does not strand the callee" {
    // The callee is the run's first operand and rides the same spill
    // the arguments do, so an `or` or an `else` between it and the call
    // cannot leave its value in a register that no longer exists.
    try agree.prints(
        \\func mark(flag: bool, n: long) -> string:
        \\    return string(flag) + ":" + string(n)
        \\
        \\func pick() -> func(bool, long) -> string:
        \\    return mark
        \\
        \\func main():
        \\    let held: long? = none
        \\    var yes = true
        \\    print(pick()(yes or len("ab") > 1, held else 9))
        \\
    , "true:9\n");
}

test "a function value in a struct field is called through a grouping" {
    // `(r.render)(3)` is the call suffix on a field read, and it meets
    // the same absence the method spelling does — narrowed into a local
    // first, it runs.
    try agree.prints(
        \\struct Rows:
        \\    render: (func(long) -> string)?
        \\
        \\func label(index: long) -> string:
        \\    return "row " + string(index)
        \\
        \\func main():
        \\    let rows = Rows(render = label)
        \\    let provider = rows.render
        \\    if provider != none:
        \\        print((provider)(4))
        \\
    , "row 4\n");
}

test "a fresh function value called in place is released with the statement" {
    // A function value owns the two-slot run that holds it
    // (docs/BINDING.md D12), and one that nothing binds is a statement
    // temporary like any other — the leak census is what proves it.
    try agree.prints(
        \\struct Counter:
        \\    step: long
        \\
        \\    func times(n: long) -> long:
        \\        return n * self.step
        \\
        \\func scaler(step: long) -> func(long) -> long:
        \\    let counter = Counter(step = step)
        \\    return counter.times
        \\
        \\func main():
        \\    var total: long = 0
        \\    for step in [1, 2, 3]:
        \\        total += scaler(step)(10)
        \\    print(string(total))
        \\
    , "60\n");
}

test "a callee borrowed from a container survives an argument that empties it" {
    // docs/STRINGS.md's residual hazard, at the callee: `m[k]` is a
    // borrow of the map's two-slot run, and an argument evaluated
    // after it could free that run.  The defensive copy the operand
    // walk makes for an argument is made for the callee too, so the
    // call still dispatches and the copy is released with the
    // statement — which the leak census is what proves.
    try agree.prints(
        \\func twice(n: long) -> long:
        \\    return n * 2
        \\
        \\func wipe(actions: map(string, func(long) -> long)) -> long:
        \\    actions.remove("double")
        \\    return 5
        \\
        \\func main():
        \\    var actions = new map(string, func(long) -> long)
        \\    actions["double"] = twice
        \\    print(string(actions["double"](wipe(actions))))
        \\    print(string(len(actions)))
        \\
    , "10\n0\n");
}
