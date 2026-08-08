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
//!     type is expected, and so is a namespace function and one
//!     reached through an import.
//!   * **S2** — the type is `func(T, ...) -> R`, and the shape a call
//!     through it takes is the shape the type wrote down.
//!   * **S3** — a lambda is a parenthesized parameter list, an arrow
//!     and one expression, and its parameter types come from the place
//!     it lands on.
//!   * **D2** — a lambda *is* the named case after the analyzer runs:
//!     the two spellings are the same instruction, and the same
//!     dispatch.
//!   * **D3** — function values compare `==`/`!=`, `string(f)` answers
//!     the function's name, and copying one costs nothing and frees
//!     nothing.
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

test "a namespace function is a value, and so is one from another module" {
    try agree.prints(
        \\import std.math
        \\
        \\struct Scale:
        \\    func twice(n: long) -> long:
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
        \\let step = 4
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

test "function values compare as the same function or a different one" {
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
        \\    print(string(f == g))
        \\    print(string(f == h))
        \\    print(string(f != h))
        \\
    , "true\nfalse\ntrue\n");
}

test "string of a function value is the function's name" {
    try agree.prints(
        \\struct Scale:
        \\    func twice(n: long) -> long:
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
        \\    print(string(twice != thrice))
        \\
    , "true\ntrue\n");
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
        \\    print(string(a == b))
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

test "a give-taking function value crosses into a worker and calls there" {
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
        \\    let work = spawn run(consume, give values)
        \\    print(string(work.wait()))
        \\
    , "10\n");
}

test "a worker can return a function value and the joiner can call it" {
    try agree.prints(
        \\func twice(n: long) -> long:
        \\    return n * 2
        \\
        \\func choose() -> func(long) -> long:
        \\    return twice
        \\
        \\func main():
        \\    let work = spawn choose()
        \\    let chosen = work.wait()
        \\    print(string(chosen(21)))
        \\
    , "42\n");
}
