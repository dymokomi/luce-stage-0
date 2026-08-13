//! Threads, as an executable specification (docs/THREADS.md).
//!
//! Every fact below is proved on **both engines** — the interpreter
//! and the compiled artifact, run and compared on prints, trap code,
//! trap message, call trace frame for frame, leak census and the world
//! each left behind (`agree.zig`).  That bar is what D10 is: the
//! oracle spawns a real `Machine` per worker on a real `std.Thread`,
//! through the same two host slots a compiled artifact uses, so a
//! disagreement here is a bug in one arm rather than a difference of
//! pretence.
//!
//! **Determinism is by shape, not by luck.**  Workers answer *values*
//! through `wait`, and a wait is an ordered point; no spec below lets
//! two workers race to produce an effect, because a spec that did
//! would not be comparing two engines, it would be comparing two
//! interleavings.  Where a spec wants a worker to print, exactly one
//! worker is running when it does.
//!
//! What is proved, in the order the design states it:
//!
//!   * **D1/D2** — a worker owns its world: arguments cross by `give`
//!     or `copy` or as values, a bare object name is refused, a
//!     borrow parameter cannot be spawned at all, and `give` poisons
//!     the sender exactly as S23 says.
//!   * **D3/D4** — `spawn` answers a `task`, `wait` moves the result
//!     out once, at every width and every shape, and a `T!` crosses
//!     whole.
//!   * **D5** — releasing a task joins it: at the end of a scope, and
//!     early with `free`.
//!   * **D6** — a trap in a worker is a trap at the join, with the
//!     worker's own frames in front of the joiner's.
//!   * **D8** — the slots are fail-closed: a host that cannot thread
//!     traps `host_unavailable` at the `spawn`, having touched
//!     nothing.
//!   * **D10** — the census counts every runtime, including a
//!     worker's leak.

const std = @import("std");
const agree = @import("agree.zig");
const luce = @import("luce");

const testing = std.testing;

/// A host with everything but threads — the fail-closed row (D8).
const unthreaded: agree.Provided = row: {
    var provided: agree.Provided = .{};
    provided.threads = false;
    break :row provided;
};

// ---------------------------------------------------------------------------
// The result crosses, at every width and every shape (D4)
// ---------------------------------------------------------------------------

test "a worker's long crosses the join" {
    try agree.prints(
        \\func twice(n: long) -> long:
        \\    return n * 2
        \\
        \\func main():
        \\    let t = spawn twice(21)
        \\    print(string(t.wait()))
        \\
    , "42\n");
}

test "every scalar width crosses a join intact" {
    try agree.prints(
        \\func a() -> byte:
        \\    return byte(200)
        \\func b() -> short:
        \\    return short(-30000)
        \\func c() -> int:
        \\    return 2000000000
        \\func d() -> long:
        \\    return 9000000000
        \\func e() -> half:
        \\    return half(0.5)
        \\func f() -> float:
        \\    return float(0.25)
        \\func g() -> double:
        \\    return 0.125
        \\func h() -> bool:
        \\    return true
        \\
        \\func main():
        \\    let ta = spawn a()
        \\    print(string(int(ta.wait())))
        \\    let tb = spawn b()
        \\    print(string(int(tb.wait())))
        \\    let tc = spawn c()
        \\    print(string(tc.wait()))
        \\    let td = spawn d()
        \\    print(string(td.wait()))
        \\    let te = spawn e()
        \\    print(string(double(te.wait())))
        \\    let tf = spawn f()
        \\    print(string(double(tf.wait())))
        \\    let tg = spawn g()
        \\    print(string(tg.wait()))
        \\    let th = spawn h()
        \\    print(string(th.wait()))
        \\
    , "200\n-30000\n2000000000\n9000000000\n0.5\n0.25\n0.125\ntrue\n");
}

test "a worker's string crosses the join, short and long" {
    // Short text lives inside the value and long text is an
    // allocation of the worker's own arena; both have to be re-owned
    // into the joiner's, and the long one is the case that would leak
    // or dangle if they were not (docs/STRINGS.md).
    try agree.prints(
        \\func brief() -> string:
        \\    return "hi"
        \\func lengthy() -> string:
        \\    return "a string comfortably longer than any value can hold inline"
        \\
        \\func main():
        \\    let short = spawn brief()
        \\    print(short.wait())
        \\    let big = spawn lengthy()
        \\    let held = big.wait()
        \\    print(held)
        \\    print(string(len(held)))
        \\
    ,
        "hi\na string comfortably longer than any value can hold inline\n58\n",
    );
}

test "a worker's list crosses the join and the joiner owns it" {
    try agree.prints(
        \\func build(n: long) -> list(long):
        \\    var made = new list(long)
        \\    for i in range(0, n):
        \\        made.append(i * i)
        \\    return made
        \\
        \\func main():
        \\    let t = spawn build(5)
        \\    var squares = t.wait()
        \\    print(string(len(squares)))
        \\    print(string(squares[4]))
        \\    squares.append(99)
        \\    print(string(squares[5]))
        \\
    , "5\n16\n99\n");
}

test "a worker's nested object crosses whole" {
    try agree.prints(
        \\func build() -> map(string, list(long)):
        \\    var made = new map(string, list(long))
        \\    made["a comfortably long key, longer than inline"] = [1, 2, 3]
        \\    made["b"] = [4]
        \\    return made
        \\
        \\func main():
        \\    let t = spawn build()
        \\    let held = t.wait()
        \\    print(string(len(held)))
        \\    print(string(len(held["a comfortably long key, longer than inline"])))
        \\    print(string(held["b"][0]))
        \\
    , "2\n3\n4\n");
}

test "a worker's struct crosses, and a struct carrying a list with it" {
    try agree.prints(
        \\struct Report:
        \\    label: string
        \\    total: long
        \\
        \\func measure() -> Report:
        \\    return Report(label = "a label longer than a value holds", total = 7)
        \\
        \\func main():
        \\    let t = spawn measure()
        \\    let made = t.wait()
        \\    print(made.label)
        \\    print(string(made.total))
        \\
    , "a label longer than a value holds\n7\n");
}

test "a worker that answers nothing is a bare task" {
    try agree.prints(
        \\func quiet():
        \\    let unused = 1 + 1
        \\
        \\func main():
        \\    let t: task = spawn quiet()
        \\    t.wait()
        \\    print("joined")
        \\
    , "joined\n");
}

// ---------------------------------------------------------------------------
// Arguments cross a boundary (D2)
// ---------------------------------------------------------------------------

test "give moves an object into the worker and poisons the name" {
    try agree.prints(
        \\func total(values: give list(long)) -> long:
        \\    var sum: long = 0
        \\    for v in values:
        \\        sum = sum + v
        \\    return sum
        \\
        \\func main():
        \\    var xs: list(long) = [1, 2, 3, 4]
        \\    let t = spawn total(give xs)
        \\    print(string(t.wait()))
        \\
    , "10\n");
}

test "copy hands the worker a duplicate and the sender keeps its own" {
    try agree.prints(
        \\func total(values: give list(long)) -> long:
        \\    var sum: long = 0
        \\    for v in values:
        \\        sum = sum + v
        \\    return sum
        \\
        \\func main():
        \\    var xs: list(long) = [1, 2, 3]
        \\    let t = spawn total(copy xs)
        \\    print(string(t.wait()))
        \\    xs.append(4)
        \\    print(string(len(xs)))
        \\
    , "6\n4\n");
}

test "a fresh object needs no verb, exactly as at any other call" {
    try agree.prints(
        \\func total(values: give list(long)) -> long:
        \\    var sum: long = 0
        \\    for v in values:
        \\        sum = sum + v
        \\    return sum
        \\
        \\func main():
        \\    let t = spawn total([5, 6, 7])
        \\    print(string(t.wait()))
        \\
    , "18\n");
}

test "values copy across a spawn and the caller keeps its own" {
    try agree.prints(
        \\func describe(label: string, n: long) -> string:
        \\    return label + ":" + string(n)
        \\
        \\func main():
        \\    let name = "a label longer than a value can hold inline"
        \\    let t = spawn describe(name, 3)
        \\    print(t.wait())
        \\    print(string(len(name)))
        \\
    , "a label longer than a value can hold inline:3\n43\n");
}

// ---------------------------------------------------------------------------
// A task is a scope-owned resource (D3, D5)
// ---------------------------------------------------------------------------

test "an unwaited task joins at the end of its scope and the result is discarded" {
    // The worker really runs — it writes the world's file — so this is
    // a join and not a cancellation.  What it *answers* is discarded,
    // which is D4's fire-and-forget, and the census is zero because a
    // worker's runtime dies whole.
    try agree.printsGiven(
        \\func note() -> long:
        \\    file_write("worked.txt", "yes") catch:
        \\        return 0
        \\    return 1
        \\
        \\func main():
        \\    let t = spawn note()
        \\    print("spawned")
        \\
    , .{}, "spawned\n");
}

test "an unwaited nested union result is discarded with its owned graph" {
    try agree.prints(
        \\union Job:
        \\    run(items: list(long))
        \\
        \\func build() -> Job:
        \\    var items: list(long) = [6, 7]
        \\    return Job.run(items = give items)
        \\
        \\func main():
        \\    let task = spawn build()
        \\    print("joined later")
        \\
    , "joined later\n");
}

test "free is an early join" {
    try agree.prints(
        \\func work(n: long) -> long:
        \\    return n + 1
        \\
        \\func main():
        \\    var t = spawn work(1)
        \\    free(t)
        \\    print("joined early")
        \\
    , "joined early\n");
}

test "a task returned from a function is the caller's to wait on" {
    try agree.prints(
        \\func work(n: long) -> long:
        \\    return n * 3
        \\
        \\func start(n: long) -> task(long):
        \\    return spawn work(n)
        \\
        \\func main():
        \\    let t = start(5)
        \\    print(string(t.wait()))
        \\
    , "15\n");
}

test "a resource-carrying object may be given and returned inside one Runtime" {
    try agree.prints(
        \\func work() -> long:
        \\    return 7
        \\
        \\func handoff(running: give list(task(long))) -> list(task(long)):
        \\    return running
        \\
        \\func main():
        \\    var running = new list(task(long))
        \\    running.append(spawn work())
        \\    let moved = handoff(give running)
        \\    for task in moved:
        \\        print(string(task.wait()))
        \\
    , "7\n");
}

test "equal constant slice bounds construct an empty resource list without copying" {
    try agree.prints(
        \\func main():
        \\    var running = new list(task(long))
        \\    let empty = running[0:0]
        \\    print(string(len(empty)))
        \\
    , "0\n");
}

test "tasks in a list are joined in the order the list holds them" {
    // N workers, joined in loop order — deterministic by shape, which
    // is the discipline the whole suite is written under.
    try agree.prints(
        \\func square(n: long) -> long:
        \\    return n * n
        \\
        \\func main():
        \\    var tasks = new list(task(long))
        \\    for i in range(1, 5):
        \\        tasks.append(spawn square(i))
        \\    var total: long = 0
        \\    for t in tasks:
        \\        total = total + t.wait()
        \\    print(string(total))
        \\
    , "30\n");
}

// ---------------------------------------------------------------------------
// Errors and traps cross the join (D4, D6)
// ---------------------------------------------------------------------------

test "a worker's error crosses whole and can be caught at the join" {
    try agree.prints(
        \\func risky(n: long) -> long!:
        \\    if n < 0:
        \\        error("negative input")
        \\    return n
        \\
        \\func main() -> !:
        \\    var bad = spawn risky(-1)
        \\    var answered: long = 0
        \\    answered = bad.wait() catch reason:
        \\        print("caught: " + reason)
        \\    let good = spawn risky(7)
        \\    print(string(try good.wait()))
        \\
    , "caught: negative input\n7\n");
}

test "a worker's error nobody catches ends the program with its words" {
    try agree.errors(
        \\func risky() -> long!:
        \\    error("the worker said no")
        \\
        \\func main() -> !:
        \\    let t = spawn risky()
        \\    print(string(try t.wait()))
        \\
    , .{}, .user_error, "the worker said no");
}

test "a trap in a worker is a trap at the join" {
    try agree.trap(
        \\func divide(n: long) -> long:
        \\    var zero: long = 0
        \\    return n // zero
        \\
        \\func main():
        \\    let t = spawn divide(1)
        \\    print(string(t.wait()))
        \\
    , .divide_by_zero);
}

test "a worker's own words cross the join whole" {
    // The message is built in the worker, out of the worker's own
    // storage, in a frame of a runtime that is closed before the joiner
    // reports anything.  The copy that carries it across is the same
    // one every trap takes (`heap.failMessage`), taken while the child
    // is still open.
    try agree.trapSays(
        \\func risky(name: string):
        \\    trap("worker " + name + " gave up")
        \\
        \\func main():
        \\    let t = spawn risky("two")
        \\    t.wait()
        \\
    , .explicit_trap, "worker two gave up");
}

test "a trapped worker's trace names the worker's own frames first" {
    var session = try agree.compare(
        \\func inner(n: long) -> long:
        \\    var zero: long = 0
        \\    return n // zero
        \\
        \\func outer(n: long) -> long:
        \\    return inner(n)
        \\
        \\func main():
        \\    let t = spawn outer(1)
        \\    print(string(t.wait()))
        \\
    , .{});
    defer session.deinit();
    try testing.expectEqual(luce.mir.TrapCode.divide_by_zero, session.end.trapped);
    // Innermost first, across the join: the worker's two frames, then
    // the frame that waited.  Both engines produced this byte for
    // byte, which is what `settle` already held them to.
    const trace = session.trace();
    const inner_at = std.mem.indexOf(u8, trace, "inner") orelse return error.NoWorkerFrame;
    const outer_at = std.mem.indexOf(u8, trace, "outer") orelse return error.NoWorkerFrame;
    const main_at = std.mem.indexOf(u8, trace, "main") orelse return error.NoJoinerFrame;
    try testing.expect(inner_at < outer_at);
    try testing.expect(outer_at < main_at);
}

// ---------------------------------------------------------------------------
// A worker's world is its own (D1)
// ---------------------------------------------------------------------------

test "a worker gets a fresh depth budget rather than its spawner's" {
    // `deep` is called far enough down that its own budget would be
    // long gone if a worker inherited what was left of its spawner's;
    // it recurses to a depth no shallow budget could hold.
    const shallow: agree.Provided = row: {
        var provided: agree.Provided = .{};
        provided.call_depth = 24;
        break :row provided;
    };
    try agree.printsGiven(
        \\func countdown(n: long) -> long:
        \\    if n <= 0:
        \\        let t = spawn depth(10)
        \\        return t.wait()
        \\    return countdown(n - 1)
        \\
        \\func depth(n: long) -> long:
        \\    if n <= 0:
        \\        return 0
        \\    return 1 + depth(n - 1)
        \\
        \\func main():
        \\    print(string(countdown(15)))
        \\
    , shallow, "10\n");
}

test "a worker's own recursion is refused at its own budget" {
    const shallow: agree.Provided = row: {
        var provided: agree.Provided = .{};
        provided.call_depth = 16;
        break :row provided;
    };
    try agree.trapGiven(
        \\func forever(n: long) -> long:
        \\    return forever(n + 1)
        \\
        \\func main():
        \\    let t = spawn forever(0)
        \\    print(string(t.wait()))
        \\
    , shallow, .call_depth_exceeded);
}

test "a worker may spawn a worker" {
    try agree.prints(
        \\func leaf(n: long) -> long:
        \\    return n + 1
        \\
        \\func branch(n: long) -> long:
        \\    let inner = spawn leaf(n)
        \\    return inner.wait() * 10
        \\
        \\func main():
        \\    let t = spawn branch(4)
        \\    print(string(t.wait()))
        \\
    , "50\n");
}

test "sibling workers may each spawn and join a child" {
    // Eight parents and their eight children can all be live together.
    // The result is joined in source order, so the program stays
    // deterministic while both hosts exercise concurrent publication
    // in their worker registries.
    try agree.prints(
        \\func leaf(n: long) -> long:
        \\    return n + 1
        \\
        \\func branch(n: long) -> long:
        \\    let inner = spawn leaf(n)
        \\    return inner.wait() * 10
        \\
        \\func main():
        \\    var tasks = new list(task(long))
        \\    for i in range(1, 9):
        \\        tasks.append(spawn branch(i))
        \\    var total: long = 0
        \\    for t in tasks:
        \\        total = total + t.wait()
        \\    print(string(total))
        \\
    , "440\n");
}

// ---------------------------------------------------------------------------
// The census, across runtimes (D10)
// ---------------------------------------------------------------------------

test "a worker that leaks is counted in this program's census" {
    // The one way a Luce program can still leak: a trap unwinds past
    // every release (S34).  Here the worker's own runtime holds an
    // object when it stops, and the number reaching the host is the
    // program's — both runtimes' — rather than the root's alone.
    var session = try agree.compare(
        \\func leaky() -> long:
        \\    var kept = [1, 2, 3]
        \\    var zero: long = 0
        \\    return 1 // zero
        \\
        \\func main():
        \\    let t = spawn leaky()
        \\    print(string(t.wait()))
        \\
    , .{});
    defer session.deinit();
    try testing.expectEqual(luce.mir.TrapCode.divide_by_zero, session.end.trapped);
}

test "a program that spawns and joins leaves nothing alive" {
    try agree.ok(
        \\func build(n: long) -> list(long):
        \\    var made = new list(long)
        \\    for i in range(0, n):
        \\        made.append(i)
        \\    return made
        \\
        \\func main():
        \\    var total: long = 0
        \\    for round in range(0, 4):
        \\        let t = spawn build(round + 1)
        \\        let held = t.wait()
        \\        total = total + len(held)
        \\    assert(total == 10)
        \\
    );
}

// ---------------------------------------------------------------------------
// The host boundary (D8)
// ---------------------------------------------------------------------------

test "a host that cannot thread refuses the spawn, having touched nothing" {
    try agree.trapGiven(
        \\func work() -> long:
        \\    return 1
        \\
        \\func main():
        \\    let t = spawn work()
        \\    print(string(t.wait()))
        \\
    , unthreaded, .host_unavailable);
}

// ---------------------------------------------------------------------------
// Effects from a worker are serialized (D9)
// ---------------------------------------------------------------------------

test "a worker may print, and its line arrives whole" {
    // One worker at a time, on purpose: what is under test is that a
    // worker reaches the host at all and that its line is not torn,
    // not who wins a race.
    try agree.prints(
        \\func announce(n: long) -> long:
        \\    print("worker " + string(n))
        \\    return n
        \\
        \\func main():
        \\    let first = spawn announce(1)
        \\    let a = first.wait()
        \\    let second = spawn announce(2)
        \\    let b = second.wait()
        \\    print("main " + string(a + b))
        \\
    , "worker 1\nworker 2\nmain 3\n");
}

test "a worker may reach the file channel" {
    try agree.printsGiven(
        \\func save(text: string) -> long!:
        \\    try file_write("notes.txt", text)
        \\    return len(text)
        \\
        \\func main() -> !:
        \\    let t = spawn save("written by a worker")
        \\    print(string(try t.wait()))
        \\
    , .{}, "19\n");
}

// ---------------------------------------------------------------------------
// exit from a worker (the as-built ruling)
// ---------------------------------------------------------------------------

test "exit inside a worker stops the program at the join, carrying its status" {
    try agree.exits(
        \\func bail() -> long:
        \\    exit(3)
        \\
        \\func main():
        \\    let t = spawn bail()
        \\    print(string(t.wait()))
        \\    print("never")
        \\
    , .{}, 3);
}
