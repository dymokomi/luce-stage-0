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
//!   * **D5** — a value-state bound value crosses a worker boundary,
//!     because its class is its receiver-state's class and that class
//!     is "value".
//!   * **D6** — `string(f)` answers the method's qualified name.
//!   * **D11's neighbour** — the receiver may be an enum as readily as
//!     a struct, because a method is a method wherever it was declared
//!     (docs/ENUMS.md D7).
//!
//! The refusals — a writing method bound, a carrying receiver bound, a
//! shape that does not fit — live in `errors_spec.zig` with every other
//! diagnostic, because a program that does not compile has no engine to
//! disagree about.

const std = @import("std");
const agree = @import("agree.zig");

// ---------------------------------------------------------------------------
// The bind itself (D1, D2)
// ---------------------------------------------------------------------------

test "a method bound to its receiver lands where a function type is expected" {
    try agree.prints(
        \\struct Scale:
        \\    factor: long
        \\
        \\    func times(n: long) -> long:
        \\        return n * self.factor
        \\
        \\func apply(n: long, f: func(long) -> long) -> long:
        \\    return f(n)
        \\
        \\func main():
        \\    let doubling = Scale(factor = 2)
        \\    let tripling = Scale(factor = 3)
        \\    print(string(apply(21, doubling.times)))
        \\    print(string(apply(21, tripling.times)))
        \\
    , "42\n63\n");
}

test "the written type drops the receiver's parameter and keeps every other" {
    try agree.prints(
        \\struct Between:
        \\    low: long
        \\    high: long
        \\
        \\    func holds(n: long, slack: long) -> bool:
        \\        return n >= self.low - slack and n <= self.high + slack
        \\
        \\func count(xs: list(long), keep: func(long, long) -> bool, slack: long) -> long:
        \\    var kept = 0
        \\    for x in xs:
        \\        if keep(x, slack):
        \\            kept = kept + 1
        \\    return kept
        \\
        \\func main():
        \\    let window = Between(low = 3, high = 6)
        \\    var xs = new list(long)
        \\    xs.append(1)
        \\    xs.append(4)
        \\    xs.append(8)
        \\    print(string(count(xs, window.holds, 0)))
        \\    print(string(count(xs, window.holds, 2)))
        \\
    , "1\n3\n");
}

test "a bind lands on a let of function type and is called through the binding" {
    try agree.prints(
        \\struct Greeter:
        \\    greeting: string
        \\
        \\    func to(name: string) -> string:
        \\        return self.greeting + ", " + name
        \\
        \\func main():
        \\    let polite = Greeter(greeting = "Good day")
        \\    let hello: func(string) -> string = polite.to
        \\    print(hello("Ada"))
        \\    print(hello("Grace"))
        \\
    , "Good day, Ada\nGood day, Grace\n");
}

test "a bound value is answered by a function and called by its caller" {
    try agree.prints(
        \\struct Offset:
        \\    by: long
        \\
        \\    func shift(n: long) -> long:
        \\        return n + self.by
        \\
        \\func shifter(by: long) -> func(long) -> long:
        \\    let made = Offset(by = by)
        \\    return made.shift
        \\
        \\func main():
        \\    let up = shifter(10)
        \\    let down = shifter(-10)
        \\    print(string(up(1)))
        \\    print(string(down(1)))
        \\
    , "11\n-9\n");
}

test "an enum receiver binds exactly as a struct receiver does" {
    try agree.prints(
        \\enum Step(byte):
        \\    one = 1
        \\    ten = 10
        \\
        \\    func from(n: long) -> long:
        \\        return n + int(self)
        \\
        \\func apply(n: long, f: func(long) -> long) -> long:
        \\    return f(n)
        \\
        \\func main():
        \\    print(string(apply(5, Step.one.from)))
        \\    print(string(apply(5, Step.ten.from)))
        \\
    , "6\n15\n");
}

// ---------------------------------------------------------------------------
// The receiver is copied in (D3)
// ---------------------------------------------------------------------------

test "the bound value carries its own receiver: writing the original misses it" {
    try agree.prints(
        \\struct Scale:
        \\    factor: long
        \\
        \\    func times(n: long) -> long:
        \\        return n * self.factor
        \\
        \\func main():
        \\    var scale = Scale(factor = 2)
        \\    let doubling: func(long) -> long = scale.times
        \\    scale.factor = 100
        \\    print(string(doubling(3)))
        \\    print(string(scale.times(3)))
        \\
    , "6\n300\n");
}

test "a receiver holding text is copied into the value and both are released" {
    try agree.prints(
        \\struct Label:
        \\    text: string
        \\
        \\    func of(n: long) -> string:
        \\        return self.text + string(n)
        \\
        \\func main():
        \\    var made = ""
        \\    var index = 0
        \\    while index < 3:
        \\        made = made + string(index)
        \\        index = index + 1
        \\    let tag = Label(text = made)
        \\    let name: func(long) -> string = tag.of
        \\    print(name(7))
        \\    print(name(8))
        \\
    , "0127\n0128\n");
}

test "a bound value copies freely into a parameter, a local and back out" {
    try agree.prints(
        \\struct Scale:
        \\    factor: long
        \\
        \\    func times(n: long) -> long:
        \\        return n * self.factor
        \\
        \\func through(f: func(long) -> long) -> func(long) -> long:
        \\    let kept = f
        \\    return kept
        \\
        \\func main():
        \\    let doubling = Scale(factor = 2)
        \\    let first: func(long) -> long = doubling.times
        \\    let second = through(first)
        \\    let third = through(second)
        \\    print(string(first(1)))
        \\    print(string(second(2)))
        \\    print(string(third(3)))
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
        \\    origin: long
        \\
        \\    func before(a: long, b: long) -> bool:
        \\        return abs(a - self.origin) < abs(b - self.origin)
        \\
        \\func main():
        \\    let near = Nearest(origin = 10)
        \\    var xs = new list(long)
        \\    xs.append(1)
        \\    xs.append(14)
        \\    xs.append(9)
        \\    xs.append(30)
        \\    xs.sort_by(near.before)
        \\    for x in xs:
        \\        print(string(x))
        \\
    , "9\n14\n1\n30\n");
}

test "two binds of one method with different receivers sort differently" {
    try agree.prints(
        \\import std.lists
        \\
        \\struct Nearest:
        \\    origin: long
        \\
        \\    func before(a: long, b: long) -> bool:
        \\        return abs(a - self.origin) < abs(b - self.origin)
        \\
        \\func main():
        \\    var xs = new list(long)
        \\    xs.append(1)
        \\    xs.append(14)
        \\    xs.append(9)
        \\    let low = Nearest(origin = 0)
        \\    xs.sort_by(low.before)
        \\    print(string(xs[0]))
        \\    let high = Nearest(origin = 20)
        \\    xs.sort_by(high.before)
        \\    print(string(xs[0]))
        \\
    , "1\n14\n");
}

// ---------------------------------------------------------------------------
// What a bound value says about itself (D6)
// ---------------------------------------------------------------------------

test "string of a bound value is the method's qualified name" {
    try agree.prints(
        \\struct Scale:
        \\    factor: long
        \\
        \\    func times(n: long) -> long:
        \\        return n * self.factor
        \\
        \\func main():
        \\    let doubling = Scale(factor = 2)
        \\    let f: func(long) -> long = doubling.times
        \\    print(string(f))
        \\
    , "Scale.times\n");
}

// ---------------------------------------------------------------------------
// The boundary a value-state bind crosses (D5)
// ---------------------------------------------------------------------------

test "a value-state bound value crosses into a worker and is called there" {
    try agree.prints(
        \\struct Scale:
        \\    factor: long
        \\
        \\    func times(n: long) -> long:
        \\        return n * self.factor
        \\
        \\func work(f: func(long) -> long, n: long) -> long:
        \\    return f(n)
        \\
        \\func main():
        \\    let doubling = Scale(factor = 3)
        \\    let f: func(long) -> long = doubling.times
        \\    let task = spawn work(f, 14)
        \\    print(string(task.wait()))
        \\
    , "42\n");
}

// ---------------------------------------------------------------------------
// A bind is not the only thing a function type holds
// ---------------------------------------------------------------------------

test "a plain function, a lambda and a bind fill one function-typed place" {
    try agree.prints(
        \\struct Scale:
        \\    factor: long
        \\
        \\    func times(n: long) -> long:
        \\        return n * self.factor
        \\
        \\func twice(n: long) -> long:
        \\    return n * 2
        \\
        \\func apply(n: long, f: func(long) -> long) -> long:
        \\    return f(n)
        \\
        \\func main():
        \\    let doubling = Scale(factor = 2)
        \\    print(string(apply(5, twice)))
        \\    print(string(apply(5, (n) -> n * 2)))
        \\    print(string(apply(5, doubling.times)))
        \\
    , "10\n10\n10\n");
}
