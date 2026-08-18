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
//!   * **D1/D2** — a worker owns its world: every permitted argument
//!     graph crosses as an independent snapshot, aliases within and
//!     between roots stay aliases, the caller remains live, and
//!     resources or functions anywhere in the graph are refused.
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

test "a worker's i64 crosses the join" {
    try agree.prints(
        \\func twice(n: i64) -> i64:
        \\    return n * 2
        \\
        \\func main():
        \\    let t = spawn twice(21)
        \\    print(str(t.wait()))
        \\
    , "42\n");
}

test "every scalar width crosses a join intact" {
    try agree.prints(
        \\func a() -> u8:
        \\    return u8(200)
        \\func b() -> i16:
        \\    return i16(-30000)
        \\func c() -> i32:
        \\    return 2000000000
        \\func d() -> i64:
        \\    return 9000000000
        \\func e() -> f16:
        \\    return f16(0.5)
        \\func f() -> f32:
        \\    return f32(0.25)
        \\func g() -> f64:
        \\    return 0.125
        \\func h() -> bool:
        \\    return true
        \\
        \\func main():
        \\    let ta = spawn a()
        \\    print(str(i32(ta.wait())))
        \\    let tb = spawn b()
        \\    print(str(i32(tb.wait())))
        \\    let tc = spawn c()
        \\    print(str(tc.wait()))
        \\    let td = spawn d()
        \\    print(str(td.wait()))
        \\    let te = spawn e()
        \\    print(str(f64(te.wait())))
        \\    let tf = spawn f()
        \\    print(str(f64(tf.wait())))
        \\    let tg = spawn g()
        \\    print(str(tg.wait()))
        \\    let th = spawn h()
        \\    print(str(th.wait()))
        \\
    , "200\n-30000\n2000000000\n9000000000\n0.5\n0.25\n0.125\ntrue\n");
}

test "a worker's str crosses the join in inline and allocated forms" {
    // Short text lives inside the value and long text is an
    // allocation of the worker's own arena; both have to be re-owned
    // into the joiner's, and the long one is the case that would leak
    // or dangle if they were not (docs/STRINGS.md).
    try agree.prints(
        \\func brief() -> str:
        \\    return "hi"
        \\func lengthy() -> str:
        \\    return "a string comfortably longer than any value can hold inline"
        \\
        \\func main():
        \\    let small = spawn brief()
        \\    print(small.wait())
        \\    let big = spawn lengthy()
        \\    let held = big.wait()
        \\    print(held)
        \\    print(str(len(held)))
        \\
    ,
        "hi\na string comfortably longer than any value can hold inline\n58\n",
    );
}

test "a worker's list crosses the join and the joiner owns it" {
    try agree.prints(
        \\func build(n: i64) -> list[i64]:
        \\    var made = list[i64]()
        \\    for i in range(0, n):
        \\        made.append(i * i)
        \\    return made
        \\
        \\func main():
        \\    let t = spawn build(5)
        \\    var squares = t.wait()
        \\    print(str(len(squares)))
        \\    print(str(squares[4]))
        \\    squares.append(99)
        \\    print(str(squares[5]))
        \\
    , "5\n16\n99\n");
}

test "a worker's nested object crosses whole" {
    try agree.prints(
        \\func build() -> map[str, list[i64]]:
        \\    var made = map[str, list[i64]]()
        \\    made["a comfortably long key, longer than inline"] = [1, 2, 3]
        \\    made["b"] = [4]
        \\    return made
        \\
        \\func main():
        \\    let t = spawn build()
        \\    let held = t.wait()
        \\    print(str(len(held)))
        \\    print(str(len(held["a comfortably long key, longer than inline"])))
        \\    print(str(held["b"][0]))
        \\
    , "2\n3\n4\n");
}

test "a worker's struct crosses, and a struct carrying a list with it" {
    try agree.prints(
        \\struct Report:
        \\    label: str
        \\    total: i64
        \\
        \\func measure() -> Report:
        \\    return Report(label = "a label longer than a value holds", total = 7)
        \\
        \\func main():
        \\    let t = spawn measure()
        \\    let made = t.wait()
        \\    print(made.label)
        \\    print(str(made.total))
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

test "values copy across a spawn and the caller keeps its own" {
    try agree.prints(
        \\func describe(label: str, n: i64) -> str:
        \\    return label + ":" + str(n)
        \\
        \\func main():
        \\    let name = "a label longer than a value can hold inline"
        \\    let t = spawn describe(name, 3)
        \\    print(t.wait())
        \\    print(str(len(name)))
        \\
    , "a label longer than a value can hold inline:3\n43\n");
}

test "a container argument is an independent worker snapshot" {
    try agree.prints(
        \\func extend(values: list[i64]) -> i64:
        \\    values.append(99)
        \\    return len(values)
        \\
        \\func main():
        \\    var original: list[i64] = [1, 2]
        \\    let task = spawn extend(original)
        \\    original.append(3)
        \\    print(str(len(original)))
        \\    print(str(task.wait()))
        \\    print(str(original[2]))
        \\
    , "3\n3\n3\n");
}

test "worker arguments preserve aliases across parameter roots" {
    try agree.prints(
        \\func extend(first: list[i64], second: list[i64]) -> i64:
        \\    first.append(9)
        \\    return len(second)
        \\
        \\func main():
        \\    var shared: list[i64] = [1]
        \\    let task = spawn extend(shared, shared)
        \\    shared.append(2)
        \\    print(str(task.wait()))
        \\    print(str(len(shared)))
        \\
    , "2\n2\n");
}

// ---------------------------------------------------------------------------
// A task is an ARC resource (D3, D5)
// ---------------------------------------------------------------------------

test "an unwaited task joins at its last release and discards the result" {
    // The worker really runs — it writes the world's file — so this is
    // a join and not a cancellation.  What it *answers* is discarded,
    // which is D4's fire-and-forget, and the census is zero because a
    // worker's runtime dies whole.
    try agree.printsGiven(
        \\import std.files
        \\
        \\func note() -> i64:
        \\    files.write("worked.txt", "yes") catch:
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
        \\    run(items: list[i64])
        \\
        \\func build() -> Job:
        \\    var items: list[i64] = [6, 7]
        \\    return Job.run(items = items)
        \\
        \\func main():
        \\    let task = spawn build()
        \\    print("joined later")
        \\
    , "joined later\n");
}

test "discarding a worker error still joins and closes its owned graph" {
    try agree.prints(
        \\union Packet:
        \\    payload(items: list[i64], label: str)
        \\
        \\func fail() -> i64!:
        \\    var items: list[i64] = [10, 11, 12]
        \\    let packet = Packet.payload(items = items, label = "discarded")
        \\    error("ignored")
        \\
        \\func main():
        \\    let task = spawn fail()
        \\    print("joined")
        \\
    , "joined\n");
}

test "a task returned from a function is the caller's to wait on" {
    try agree.prints(
        \\func work(n: i64) -> i64:
        \\    return n * 3
        \\
        \\func start(n: i64) -> task[i64]:
        \\    return spawn work(n)
        \\
        \\func main():
        \\    let t = start(5)
        \\    print(str(t.wait()))
        \\
    , "15\n");
}

test "a struct composes a union optional task callback and recursive children" {
    try agree.prints(
        \\union Job:
        \\    idle
        \\    running(task: task[i64]?)
        \\
        \\struct Envelope:
        \\    job: Job
        \\    callback: (func(i64) -> i64)?
        \\    children: list[Envelope]
        \\
        \\func work() -> i64:
        \\    return 21
        \\
        \\func twice(value: i64) -> i64:
        \\    return value * 2
        \\
        \\func apply(callback: (func(i64) -> i64)?, value: i64) -> i64:
        \\    let chosen = callback else twice
        \\    return chosen(value)
        \\
        \\func consume(packet: Envelope) -> i64:
        \\    match packet.job:
        \\        idle:
        \\            return 0
        \\        running(task):
        \\            if task == none:
        \\                return apply(packet.callback, 0)
        \\            return apply(packet.callback, task.wait())
        \\
        \\func main():
        \\    let packet = Envelope(
        \\        job = Job.running(task = spawn work()),
        \\        callback = twice,
        \\        children = list[Envelope](),
        \\    )
        \\    print(str(consume(packet)))
        \\
    , "42\n");
}

test "a resource graph survives union optional container give return and failure" {
    try agree.prints(
        \\union Parcel:
        \\    loaded(tasks: list[task[i64]], extra: task[i64]?)
        \\
        \\struct Crate:
        \\    parcel: Parcel
        \\    callback: (func(i64) -> i64)?
        \\    contents: map[str, i64]
        \\    grid: array[i64, _]
        \\
        \\func work(value: i64) -> i64:
        \\    return value
        \\
        \\func identity(value: i64) -> i64:
        \\    return value
        \\
        \\func bump(value: i64) -> i64:
        \\    return value + 1
        \\
        \\func route(crate: Crate) -> Crate:
        \\    return crate
        \\
        \\func finish(parcel: Parcel, callback: (func(i64) -> i64)?, fail: bool) -> Crate!:
        \\    var contents = map[str, i64]()
        \\    contents["kind"] = 1
        \\    var grid = array[i64](2)
        \\    grid.fill(7)
        \\    let crate = Crate(
        \\        parcel = parcel,
        \\        callback = callback,
        \\        contents = contents,
        \\        grid = grid,
        \\    )
        \\    if fail:
        \\        error("discarded crate")
        \\    return route(crate)
        \\
        \\func absent(fail: bool) -> Crate!:
        \\    var tasks = list[task[i64]]()
        \\    tasks.append(spawn work(2))
        \\    let parcel = Parcel.loaded(tasks = tasks, extra = none)
        \\    return try finish(parcel, none, fail)
        \\
        \\func present(fail: bool) -> Crate!:
        \\    var tasks = list[task[i64]]()
        \\    tasks.append(spawn work(2))
        \\    let parcel = Parcel.loaded(tasks = tasks, extra = spawn work(3))
        \\    return try finish(parcel, bump, fail)
        \\
        \\func consume(crate: Crate) -> i64:
        \\    let chosen = crate.callback else identity
        \\    var total = crate.contents["kind"] + crate.grid[0]
        \\    match crate.parcel:
        \\        loaded(tasks, extra):
        \\            for running in tasks:
        \\                total = total + running.wait()
        \\            if extra != none:
        \\                total = total + extra.wait()
        \\    return chosen(total)
        \\
        \\func main() -> !:
        \\    let without_extra = try absent(false)
        \\    print(str(consume(without_extra)))
        \\    let with_extra = try present(false)
        \\    print(str(consume(with_extra)))
        \\    var failed_absent: Crate? = none
        \\    failed_absent = absent(true) catch reason:
        \\        print("caught: " + reason)
        \\    var failed_present: Crate? = none
        \\    failed_present = present(true) catch reason:
        \\        print("caught: " + reason)
        \\
    , "10\n14\ncaught: discarded crate\ncaught: discarded crate\n");
}

test "a task is consumed exactly once through a union optional field" {
    try agree.prints(
        \\union Slot:
        \\    running(task: task[i64]?)
        \\
        \\func work() -> i64:
        \\    return 4
        \\
        \\func main():
        \\    var running = spawn work()
        \\    let slot = Slot.running(task = running)
        \\    match slot:
        \\        running(task):
        \\            if task != none:
        \\                print(str(task.wait()))
        \\
    , "4\n");
}

test "a list slice retains resource elements after the source releases them" {
    try agree.prints(
        \\func work() -> i64:
        \\    return 17
        \\
        \\func main():
        \\    var running = list[task[i64]]()
        \\    running.append(spawn work())
        \\    let kept = running[0:1]
        \\    running.clear()
        \\    print(str(kept[0].wait()))
        \\
    , "17\n");
}

test "map values retain resource elements after the map releases them" {
    try agree.prints(
        \\func work() -> i64:
        \\    return 23
        \\
        \\func main():
        \\    var running = map[str, task[i64]]()
        \\    running["job"] = spawn work()
        \\    let kept = running.values()
        \\    running.clear()
        \\    print(str(kept[0].wait()))
        \\
    , "23\n");
}

test "tasks in a list are joined in the order the list holds them" {
    // N workers, joined in loop order — deterministic by shape, which
    // is the discipline the whole suite is written under.
    try agree.prints(
        \\func square(n: i64) -> i64:
        \\    return n * n
        \\
        \\func main():
        \\    var tasks = list[task[i64]]()
        \\    for i in range(1, 5):
        \\        tasks.append(spawn square(i))
        \\    var total: i64 = 0
        \\    for t in tasks:
        \\        total = total + t.wait()
        \\    print(str(total))
        \\
    , "30\n");
}

// ---------------------------------------------------------------------------
// Errors and traps cross the join (D4, D6)
// ---------------------------------------------------------------------------

test "a worker's error crosses whole and can be caught at the join" {
    try agree.prints(
        \\func risky(n: i64) -> i64!:
        \\    if n < 0:
        \\        error("negative input")
        \\    return n
        \\
        \\func main() -> !:
        \\    var bad = spawn risky(-1)
        \\    var answered: i64 = 0
        \\    answered = bad.wait() catch reason:
        \\        print("caught: " + reason)
        \\    let good = spawn risky(7)
        \\    print(str(try good.wait()))
        \\
    , "caught: negative input\n7\n");
}

test "a worker's error nobody catches ends the program with its words" {
    try agree.errors(
        \\func risky() -> i64!:
        \\    error("the worker said no")
        \\
        \\func main() -> !:
        \\    let t = spawn risky()
        \\    print(str(try t.wait()))
        \\
    , .{}, .user_error, "the worker said no");
}

test "nested worker errors unwind owned graphs at both joins" {
    // The error crosses two joins: the leaf first unwinds a union carrying
    // an owned list, then the parent worker propagates the adopted error to
    // the main runtime.  Both task rows must be consumed exactly once.
    try agree.prints(
        \\union Packet:
        \\    payload(items: list[i64], label: str)
        \\
        \\func leaf() -> i64!:
        \\    var items: list[i64] = [1, 2, 3]
        \\    let packet = Packet.payload(items = items, label = "nested")
        \\    error("nested failure")
        \\
        \\func branch() -> i64!:
        \\    let child = spawn leaf()
        \\    return try child.wait()
        \\
        \\func main() -> !:
        \\    let outer = spawn branch()
        \\    var answer: i64 = 0
        \\    answer = outer.wait() catch reason:
        \\        print("caught: " + reason)
        \\    print("after")
        \\
    , "caught: nested failure\nafter\n");
}

test "a trap in a worker is a trap at the join" {
    try agree.trap(
        \\func divide(n: i64) -> i64:
        \\    var zero: i64 = 0
        \\    return n // zero
        \\
        \\func main():
        \\    let t = spawn divide(1)
        \\    print(str(t.wait()))
        \\
    , .divide_by_zero);
}

test "a worker trap unwinds a nested union graph before the join" {
    try agree.trap(
        \\union Job:
        \\    run(items: list[i64], label: str)
        \\
        \\func boom() -> i64:
        \\    var items: list[i64] = [4, 5, 6]
        \\    let job = Job.run(items = items, label = "worker")
        \\    var zero: i64 = 0
        \\    return 1 // zero
        \\
        \\func main():
        \\    let task = spawn boom()
        \\    task.wait()
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
        \\func risky(name: str):
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
        \\func inner(n: i64) -> i64:
        \\    var zero: i64 = 0
        \\    return n // zero
        \\
        \\func outer(n: i64) -> i64:
        \\    return inner(n)
        \\
        \\func main():
        \\    let t = spawn outer(1)
        \\    print(str(t.wait()))
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
        \\func countdown(n: i64) -> i64:
        \\    if n <= 0:
        \\        let t = spawn depth(10)
        \\        return t.wait()
        \\    return countdown(n - 1)
        \\
        \\func depth(n: i64) -> i64:
        \\    if n <= 0:
        \\        return 0
        \\    return 1 + depth(n - 1)
        \\
        \\func main():
        \\    print(str(countdown(15)))
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
        \\func forever(n: i64) -> i64:
        \\    return forever(n + 1)
        \\
        \\func main():
        \\    let t = spawn forever(0)
        \\    print(str(t.wait()))
        \\
    , shallow, .call_depth_exceeded);
}

test "a worker may spawn a worker" {
    try agree.prints(
        \\func leaf(n: i64) -> i64:
        \\    return n + 1
        \\
        \\func branch(n: i64) -> i64:
        \\    let inner = spawn leaf(n)
        \\    return inner.wait() * 10
        \\
        \\func main():
        \\    let t = spawn branch(4)
        \\    print(str(t.wait()))
        \\
    , "50\n");
}

test "sibling workers may each spawn and join a child" {
    // Eight parents and their eight children can all be live together.
    // The result is joined in source order, so the program stays
    // deterministic while both hosts exercise concurrent publication
    // in their worker registries.
    try agree.prints(
        \\func leaf(n: i64) -> i64:
        \\    return n + 1
        \\
        \\func branch(n: i64) -> i64:
        \\    let inner = spawn leaf(n)
        \\    return inner.wait() * 10
        \\
        \\func main():
        \\    var tasks = list[task[i64]]()
        \\    for i in range(1, 9):
        \\        tasks.append(spawn branch(i))
        \\    var total: i64 = 0
        \\    for t in tasks:
        \\        total = total + t.wait()
        \\    print(str(total))
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
        \\func leaky() -> i64:
        \\    var kept = [1, 2, 3]
        \\    var zero: i64 = 0
        \\    return 1 // zero
        \\
        \\func main():
        \\    let t = spawn leaky()
        \\    print(str(t.wait()))
        \\
    , .{});
    defer session.deinit();
    try testing.expectEqual(luce.mir.TrapCode.divide_by_zero, session.end.trapped);
}

test "a program that spawns and joins leaves nothing alive" {
    try agree.ok(
        \\func build(n: i64) -> list[i64]:
        \\    var made = list[i64]()
        \\    for i in range(0, n):
        \\        made.append(i)
        \\    return made
        \\
        \\func main():
        \\    var total: i64 = 0
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
        \\func work() -> i64:
        \\    return 1
        \\
        \\func main():
        \\    let t = spawn work()
        \\    print(str(t.wait()))
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
        \\func announce(n: i64) -> i64:
        \\    print("worker " + str(n))
        \\    return n
        \\
        \\func main():
        \\    let first = spawn announce(1)
        \\    let a = first.wait()
        \\    let second = spawn announce(2)
        \\    let b = second.wait()
        \\    print("main " + str(a + b))
        \\
    , "worker 1\nworker 2\nmain 3\n");
}

test "a worker may reach the file channel" {
    try agree.printsGiven(
        \\import std.files
        \\
        \\func save(text: str) -> i64!:
        \\    try files.write("notes.txt", text)
        \\    return len(text)
        \\
        \\func main() -> !:
        \\    let t = spawn save("written by a worker")
        \\    print(str(try t.wait()))
        \\
    , .{}, "19\n");
}

// ---------------------------------------------------------------------------
// exit from a worker (the as-built ruling)
// ---------------------------------------------------------------------------

test "exit inside a worker stops the program at the join, carrying its status" {
    try agree.exits(
        \\func bail() -> i64:
        \\    exit(3)
        \\
        \\func main():
        \\    let t = spawn bail()
        \\    print(str(t.wait()))
        \\    print("never")
        \\
    , .{}, 3);
}

test "worker exit unwinds a nested union graph before the join" {
    try agree.exits(
        \\union Job:
        \\    run(items: list[i64], label: str)
        \\
        \\func bail() -> i64:
        \\    var items: list[i64] = [7, 8, 9]
        \\    let job = Job.run(items = items, label = "worker")
        \\    exit(11)
        \\
        \\func main():
        \\    let task = spawn bail()
        \\    task.wait()
        \\
    , .{}, 11);
}
