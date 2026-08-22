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
//!     `str(f)` answers the function's name, and copying one costs
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

test "standard implementation names and receiver method names remain ordinary identifiers" {
    // Host services are reached through std modules, and a method's receiver
    // already chooses its namespace. Neither category confiscates a bare
    // program name.
    try agree.prints(
        \\import std.files
        \\
        \\func dir_create() -> str:
        \\    return "directory"
        \\
        \\func term_rows() -> str:
        \\    return "terminal"
        \\
        \\func append(left: str, right: str) -> str:
        \\    return left + right
        \\
        \\func main():
        \\    let clock_ms = "clock"
        \\    print(append(dir_create(), "/" + term_rows()) + "/" + clock_ms)
        \\
    , "directory/terminal/clock\n");
}

test "Builtin is an ordinary user namespace outside the embedded standard library" {
    // Source provenance grants the compiler bridge; the letters do not.
    // A project can therefore own this namespace without gaining or losing
    // any language power.
    try agree.prints(
        \\import std.os
        \\
        \\struct Builtin:
        \\    static func clock_ms() -> i64:
        \\        return 17
        \\
        \\func main():
        \\    print(str(Builtin.clock_ms()))
        \\
    , "17\n");
}

test "a named function passed to a function-typed parameter is called through" {
    try agree.prints(
        \\func ascending(a: i64, b: i64) -> bool:
        \\    return a < b
        \\
        \\func descending(a: i64, b: i64) -> bool:
        \\    return a > b
        \\
        \\func pick(before: func(i64, i64) -> bool, a: i64, b: i64) -> i64:
        \\    if before(a, b):
        \\        return a
        \\    return b
        \\
        \\func main():
        \\    print(str(pick(ascending, 3, 7)))
        \\    print(str(pick(descending, 3, 7)))
        \\
    , "3\n7\n");
}

test "a let of function type holds a function and calls it" {
    try agree.prints(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func main():
        \\    let f: func(i64) -> i64 = twice
        \\    print(str(f(21)))
        \\
    , "42\n");
}

test "a static member function is a value, and so is one from another module" {
    try agree.prints(
        \\import std.math
        \\
        \\struct Scale:
        \\    static func twice(n: i64) -> i64:
        \\        return n * 2
        \\
        \\func apply(f: func(i64) -> i64, x: i64) -> i64:
        \\    return f(x)
        \\
        \\func applyDouble(f: func(f64) -> f64, x: f64) -> f64:
        \\    return f(x)
        \\
        \\func main():
        \\    print(str(apply(Scale.twice, 5)))
        \\    print(str(applyDouble(math.round, 2.75)))
        \\
    , "10\n3\n");
}

test "a function value answering nothing is called as a statement" {
    try agree.prints(
        \\func shout(word: str):
        \\    print(word + "!")
        \\
        \\func twice(say: func(str), word: str):
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
        \\    x: i64
        \\    y: i64
        \\
        \\func flip(p: Point) -> Point:
        \\    return Point(x = p.y, y = p.x)
        \\
        \\func total(xs: list[i64]) -> i64:
        \\    var sum: i64 = 0
        \\    for n in xs:
        \\        sum = sum + n
        \\    return sum
        \\
        \\func label(n: i64) -> str:
        \\    return f"n={n}"
        \\
        \\func main():
        \\    let turn: func(Point) -> Point = flip
        \\    let sum: func(list[i64]) -> i64 = total
        \\    let say: func(i64) -> str = label
        \\    let p = turn(Point(x = 1, y = 2))
        \\    print(str(p.x) + "," + str(p.y))
        \\    let xs: list[i64] = [1, 2, 3]
        \\    print(str(sum(xs)))
        \\    print(say(7))
        \\
    , "2,1\n6\nn=7\n");
}

// ---------------------------------------------------------------------------
// Lambdas (S3, D2)
// ---------------------------------------------------------------------------

test "a lambda takes its parameter types from the place it lands on" {
    try agree.prints(
        \\func pick(before: func(i64, i64) -> bool, a: i64, b: i64) -> i64:
        \\    if before(a, b):
        \\        return a
        \\    return b
        \\
        \\func main():
        \\    print(str(pick((a, b) => a < b, 3, 7)))
        \\    print(str(pick((a, b) => a > b, 3, 7)))
        \\
    , "3\n7\n");
}

test "a lambda lands on a let, and on a value whose type it never wrote" {
    try agree.prints(
        \\func main():
        \\    let halve: func(f64) -> f64 = (x) => x / 2.0
        \\    let near: func(i64) -> bool = (n) => n < 10
        \\    print(str(halve(5.0)))
        \\    print(str(near(3)))
        \\    print(str(near(30)))
        \\
    , "2.5\ntrue\nfalse\n");
}

test "a lambda with no parameters, and one answering nothing" {
    try agree.prints(
        \\func run(f: func() -> i64) -> i64:
        \\    return f()
        \\
        \\func each(say: func(str), word: str):
        \\    say(word)
        \\
        \\func main():
        \\    print(str(run(() => 7)))
        \\    each((w) => print(w + "."), "here")
        \\
    , "7\nhere.\n");
}

test "a lambda's body may name a constant and call a visible function" {
    try agree.prints(
        \\import std.math
        \\
        \\const step = 4
        \\
        \\func triple(n: i64) -> i64:
        \\    return n * 3
        \\
        \\func apply(f: func(i64) -> i64, x: i64) -> i64:
        \\    return f(x)
        \\
        \\func read(f: func() -> f64) -> f64:
        \\    return f()
        \\
        \\func apply_double(f: func(f64) -> f64, x: f64) -> f64:
        \\    return f(x)
        \\
        \\func main():
        \\    print(str(apply((n) => n + step, 1)))
        \\    print(str(apply((n) => triple(n) + step, 2)))
        \\    assert(read(() => math.pi) > 3.0)
        \\    assert(apply_double((x) => math.round(x), 2.75) == 3.0)
        \\
    , "5\n10\n");
}

test "a lambda is the named case: the two spellings run the same way" {
    try agree.prints(
        \\func ascending(a: i64, b: i64) -> bool:
        \\    return a < b
        \\
        \\func pick(before: func(i64, i64) -> bool, a: i64, b: i64) -> i64:
        \\    if before(a, b):
        \\        return a
        \\    return b
        \\
        \\func main():
        \\    print(str(pick(ascending, 3, 7)))
        \\    print(str(pick((a, b) => a < b, 3, 7)))
        \\
    , "3\n3\n");
}

test "a lambda nested inside a lambda's body is a function of its own" {
    try agree.prints(
        \\func apply(f: func(i64) -> i64, x: i64) -> i64:
        \\    return f(x)
        \\
        \\func twice(f: func(i64) -> i64, x: i64) -> i64:
        \\    return f(f(x))
        \\
        \\func main():
        \\    print(str(twice((n) => apply((m) => m + 1, n), 5)))
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
        \\func up(a: i64, b: i64) -> bool:
        \\    return a < b
        \\
        \\func down(a: i64, b: i64) -> bool:
        \\    return a > b
        \\
        \\func main():
        \\    let f: func(i64, i64) -> bool = up
        \\    let g: func(i64, i64) -> bool = up
        \\    let h: func(i64, i64) -> bool = down
        \\    print(str(str(f) == str(g)))
        \\    print(str(str(f) == str(h)))
        \\
    , "true\nfalse\n");
}

test "str of a function value is the function's name" {
    try agree.prints(
        \\struct Scale:
        \\    static func twice(n: i64) -> i64:
        \\        return n * 2
        \\
        \\func halve(n: i64) -> i64:
        \\    return n // 2
        \\
        \\func name(f: func(i64) -> i64) -> str:
        \\    return str(f)
        \\
        \\func main():
        \\    print(name(halve))
        \\    print(name(Scale.twice))
        \\
    , "halve\nScale.twice\n");
}

test "str gives sibling lambdas distinct compiler function names" {
    try agree.prints(
        \\func main():
        \\    let twice: func(i64) -> i64 = (n) => n * 2
        \\    let thrice: func(i64) -> i64 = (n) => n * 3
        \\    print(str(str(twice) != str(thrice)))
        \\
    , "true\n");
}

test "a function value copies freely, into a local, a parameter and back out" {
    try agree.prints(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func chosen() -> func(i64) -> i64:
        \\    return twice
        \\
        \\func through(f: func(i64) -> i64) -> func(i64) -> i64:
        \\    let kept = f
        \\    return kept
        \\
        \\func main():
        \\    let a = chosen()
        \\    let b = through(a)
        \\    print(str(b(4)))
        \\    print(str(str(a) == str(b)))
        \\
    , "8\ntrue\n");
}

// ---------------------------------------------------------------------------
// Ownership travels through the value (D5)
// ---------------------------------------------------------------------------

test "a borrowing function value leaves its argument with its owner" {
    try agree.prints(
        \\func total(xs: list[i64]) -> i64:
        \\    var sum: i64 = 0
        \\    for n in xs:
        \\        sum = sum + n
        \\    return sum
        \\
        \\func twice(f: func(list[i64]) -> i64, xs: list[i64]) -> i64:
        \\    return f(xs) + f(xs)
        \\
        \\func main():
        \\    let xs: list[i64] = [1, 2, 3]
        \\    print(str(twice(total, xs)))
        \\    print(str(len(xs)))
        \\
    , "12\n3\n");
}

// ---------------------------------------------------------------------------
// A function value is a call in flight: everything a call promises
// ---------------------------------------------------------------------------

test "a trap inside a function value's callee names the callee in the trace" {
    try agree.trap(
        \\func bad(n: i64) -> i64:
        \\    return n // 0
        \\
        \\func apply(f: func(i64) -> i64, x: i64) -> i64:
        \\    return f(x)
        \\
        \\func main():
        \\    var n = 1
        \\    print(str(apply(bad, n)))
        \\
    , .divide_by_zero);
}

test "recursion through a function value exhausts the same budget a call does" {
    try agree.trap(
        \\func down(f: func(i64) -> i64, n: i64) -> i64:
        \\    return f(n)
        \\
        \\func step(n: i64) -> i64:
        \\    return down(step, n + 1)
        \\
        \\func main():
        \\    var n = 0
        \\    print(str(down(step, n)))
        \\
    , .call_depth_exceeded);
}

test "a function value chosen by a branch dispatches to whichever was chosen" {
    try agree.prints(
        \\func up(a: i64, b: i64) -> bool:
        \\    return a < b
        \\
        \\func down(a: i64, b: i64) -> bool:
        \\    return a > b
        \\
        \\func pick(rising: bool) -> func(i64, i64) -> bool:
        \\    if rising:
        \\        return up
        \\    return down
        \\
        \\func main():
        \\    var which = true
        \\    var seen = 0
        \\    while seen < 2:
        \\        let f = pick(which)
        \\        print(str(f(1, 2)))
        \\        which = not which
        \\        seen = seen + 1
        \\
    , "true\nfalse\n");
}

// A function value does not cross a worker boundary (docs/BINDING.md
// D4, as amended): code identity belongs to one module/runtime and a
// function type cannot say whether this value carries a receiver.  Both
// refusals are proved in `errors_spec.zig`.

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
        \\func plain(n: i64) -> str:
        \\    return "n=" + str(n)
        \\
        \\func chooser() -> func(i64) -> str:
        \\    return plain
        \\
        \\func main():
        \\    print(chooser()(5))
        \\
    , "n=5\n");
}

test "a chain of calls dispatches left to right" {
    try agree.prints(
        \\func add(n: i64) -> str:
        \\    return str(n)
        \\
        \\func pick() -> func(i64) -> str:
        \\    return add
        \\
        \\func picker() -> func() -> func(i64) -> str:
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
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func negate(n: i64) -> i64:
        \\    return 0 - n
        \\
        \\func main():
        \\    var actions = map[str, func(i64) -> i64]()
        \\    actions["double"] = twice
        \\    actions["negate"] = negate
        \\    print(str(actions["double"](21)))
        \\    print(str(actions["negate"](21)))
        \\
    , "42\n-21\n");
}

test "a stored bound method is called out of the map that holds it" {
    // The receiver rides in the value (docs/BINDING.md D3), so calling
    // it in place calls it on the state it carries.
    try agree.prints(
        \\struct Counter:
        \\    step: i64
        \\
        \\    func times(n: i64) -> i64:
        \\        return n * self.step
        \\
        \\func main():
        \\    let two = Counter(step = 2)
        \\    let three = Counter(step = 3)
        \\    var scales = map[str, func(i64) -> i64]()
        \\    scales["two"] = two.times
        \\    scales["three"] = three.times
        \\    print(str(scales["two"](10)))
        \\    print(str(scales["three"](10)))
        \\
    , "20\n30\n");
}

test "a bound method carries a union callback into another struct's function" {
    // This is the composition seam where three representations meet: the
    // bound method owns a retained Envelope receiver, which contains a
    // tagged union with an optional function value, and Runner accepts that
    // value through an ordinary function-typed parameter.
    try agree.prints(
        \\union Job:
        \\    action(run: (func(i64) -> i64)?, value: i64)
        \\
        \\struct Runner:
        \\    bias: i64
        \\
        \\    func apply(f: func(i64) -> i64, value: i64) -> i64:
        \\        return f(value + self.bias)
        \\
        \\struct Envelope:
        \\    job: Job
        \\    runner: Runner
        \\
        \\    func run() -> i64:
        \\        match self.job:
        \\            action(run, value):
        \\                let chosen = run else identity
        \\                return self.runner.apply(chosen, value)
        \\
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func identity(n: i64) -> i64:
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
        \\    let first: func() -> i64 = with_callback.run
        \\    let second: func() -> i64 = without_callback.run
        \\    print(str(first()))
        \\    print(str(second()))
        \\
    , "30\n15\n");
}

test "a field narrowed into a local is still called through the local" {
    // The path a callback-bearing value takes: a field cannot be narrowed,
    // so the optional function is bound first.
    try agree.prints(
        \\struct Rows:
        \\    render: (func(i64) -> str)?
        \\
        \\func label(index: i64) -> str:
        \\    return "row " + str(index)
        \\
        \\func main():
        \\    let rows = Rows(render = label)
        \\    let provider = rows.render
        \\    if provider != none:
        \\        print(provider(3))
        \\    let empty = Rows(render = none)
        \\    let missing = empty.render
        \\    print(str(missing == none))
        \\
    , "row 3\ntrue\n");
}

test "a call suffix answering nothing stands as a statement" {
    try agree.prints(
        \\func shout(n: i64):
        \\    print("n=" + str(n))
        \\
        \\func pick() -> func(i64):
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
        \\func note(text: str) -> i64:
        \\    print(text)
        \\    return 1
        \\
        \\func sum(a: i64, b: i64) -> i64:
        \\    return a + b
        \\
        \\func chooser() -> func(i64, i64) -> i64:
        \\    print("callee")
        \\    return sum
        \\
        \\func main():
        \\    print(str(chooser()(note("first"), note("second"))))
        \\
    , "callee\nfirst\nsecond\n2\n");
}

test "an argument that opens a block does not strand the callee" {
    // The callee is the run's first operand and rides the same spill
    // the arguments do, so an `or` or an `else` between it and the call
    // cannot leave its value in a register that no longer exists.
    try agree.prints(
        \\func mark(flag: bool, n: i64) -> str:
        \\    return str(flag) + ":" + str(n)
        \\
        \\func pick() -> func(bool, i64) -> str:
        \\    return mark
        \\
        \\func main():
        \\    let held: i64? = none
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
        \\    render: (func(i64) -> str)?
        \\
        \\func label(index: i64) -> str:
        \\    return "row " + str(index)
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
        \\    step: i64
        \\
        \\    func times(n: i64) -> i64:
        \\        return n * self.step
        \\
        \\func scaler(step: i64) -> func(i64) -> i64:
        \\    let counter = Counter(step = step)
        \\    return counter.times
        \\
        \\func main():
        \\    var total: i64 = 0
        \\    for step in [1, 2, 3]:
        \\        total += scaler(step)(10)
        \\    print(str(total))
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
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func wipe(actions: map[str, func(i64) -> i64]) -> i64:
        \\    actions.remove("double")
        \\    return 5
        \\
        \\func main():
        \\    var actions = map[str, func(i64) -> i64]()
        \\    actions["double"] = twice
        \\    print(str(actions["double"](wipe(actions))))
        \\    print(str(len(actions)))
        \\
    , "10\n0\n");
}
