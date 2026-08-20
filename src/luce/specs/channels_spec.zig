//! Channels — the one reference that crosses workers
//! (docs/THREADS.md).
//!
//! The single-runtime semantics run on both engines like every spec:
//! construction and capacity, FIFO order, the closed error after the
//! drain, the try and timed forms, and the leak census proving the
//! wrapper and every parked graph are released.  The cross-worker
//! sessions then stream real values between real threads on both
//! engines — the reason the feature exists.

const std = @import("std");
const luce = @import("luce");
const agree = @import("agree.zig");

const testing = std.testing;
const compile_mod = luce.compile;

/// Workers park and wake inside these programs, so the depth budget is
/// the ordinary one; hosted access is never needed.
const budget: agree.Provided = .{ .call_depth = 4096 };

fn agreeOk(source: []const u8) !void {
    return agree.okGiven(source, budget);
}

fn expectRejected(source: []const u8, code: []const u8) !void {
    var result = try compile_mod.compile(testing.allocator, source, .{});
    defer result.deinit();
    switch (result) {
        .success => return error.TestUnexpectedResult,
        .failure => |diagnostics| {
            for (0..diagnostics.count()) |index| {
                if (std.mem.eql(u8, diagnostics.at(index).?.code, code)) return;
            }
            return error.TestUnexpectedResult;
        },
    }
}

test "channels: construction, capacity, and length agree" {
    try agreeOk(
        \\func main():
        \\    var c = channel[i64](4)
        \\    assert(c.cap() == 4)
        \\    assert(c.len() == 0)
        \\    var d = channel[str]()
        \\    assert(d.cap() == 16)
        \\    var tiny = channel[i64](0)
        \\    assert(tiny.cap() == 1)
        \\
    );
}

test "channels: values come back in send order, rebuilt whole" {
    // FIFO is promised; identity is not — the received struct is a
    // rebuilt graph, so mutating the original after the send cannot
    // reach what was parked.
    try agreeOk(
        \\struct Point:
        \\    x: i64
        \\    y: i64
        \\
        \\func main() -> !:
        \\    var c = channel[Point](4)
        \\    var here = Point(x = 1, y = 2)
        \\    try c.send(here)
        \\    here.x = 99
        \\    try c.send(here)
        \\    let first = try c.receive()
        \\    let second = try c.receive()
        \\    assert(first.x == 1 and first.y == 2)
        \\    assert(second.x == 99)
        \\
    );
}

test "channels: close drains first and then says so, idempotently" {
    try agreeOk(
        \\func main() -> !:
        \\    var c = channel[i64](4)
        \\    try c.send(7)
        \\    c.close()
        \\    c.close()
        \\    assert(try c.receive() == 7)
        \\    var said = ""
        \\    var value: i64 = -1
        \\    value = c.receive() catch reason:
        \\        said = reason
        \\    assert(value == -1)
        \\    assert(said == "the channel is closed")
        \\    var refused = ""
        \\    c.send(1) catch reason:
        \\        refused = reason
        \\    assert(refused == "the channel is closed")
        \\
    );
}

test "channels: the try and timed forms answer absence, not errors" {
    try agreeOk(
        \\func main() -> !:
        \\    var c = channel[i64](1)
        \\    assert((try c.try_receive()) == none)
        \\    assert((try c.receive_timeout(1)) == none)
        \\    assert(try c.try_send(5))
        \\    assert(not try c.try_send(6))
        \\    assert(((try c.try_receive()) else -1) == 5)
        \\
    );
}

test "channels: text crosses whole" {
    try agreeOk(
        \\func main() -> !:
        \\    var c = channel[str](2)
        \\    try c.send("héllo " + "wörld")
        \\    let landed = try c.receive()
        \\    assert(landed == "héllo wörld")
        \\    assert(len(landed) == 11)
        \\
    );
}

test "channels: a worker streams into the spawner" {
    try agreeOk(
        \\func produce(out: channel[i64], count: i64):
        \\    for step in range(0, count):
        \\        out.send(step * 10) catch:
        \\            return
        \\    out.close()
        \\
        \\func main() -> !:
        \\    var c = channel[i64](2)
        \\    let worker = spawn produce(c, 5)
        \\    var total: i64 = 0
        \\    var rounds = 0
        \\    while true:
        \\        let got = c.receive() catch:
        \\            break
        \\        total += got
        \\        rounds += 1
        \\    worker.wait()
        \\    assert(total == 100)
        \\    assert(rounds == 5)
        \\
    );
}

test "channels: many workers fan into one channel" {
    // MPMC under real contention: three producers, one consumer, a
    // capacity smaller than the traffic — the bounded queue blocks and
    // wakes senders, and every value arrives exactly once.
    try agreeOk(
        \\func produce(out: channel[i64], base: i64):
        \\    for step in range(0, 20):
        \\        out.send(base + step) catch:
        \\            return
        \\
        \\func main() -> !:
        \\    var c = channel[i64](3)
        \\    let first = spawn produce(c, 0)
        \\    let second = spawn produce(c, 100)
        \\    let third = spawn produce(c, 200)
        \\    var total: i64 = 0
        \\    for round in range(0, 60):
        \\        total += try c.receive()
        \\    first.wait()
        \\    second.wait()
        \\    third.wait()
        \\    c.close()
        \\    # three of (0+..+19) plus 20*100 plus 20*200
        \\    assert(total == 6570)
        \\
    );
}

test "channels: a channel element that cannot cross is refused where it is written" {
    try expectRejected(
        \\import std.files
        \\
        \\func main():
        \\    var c = channel[files.File](2)
        \\
    , "luce.sema.channel");
    try expectRejected(
        \\class Counter:
        \\    count: i64
        \\
        \\    init():
        \\        self.count = 0
        \\
        \\func main():
        \\    var c = channel[Counter](2)
        \\
    , "luce.sema.channel");
}

test "receive_by: the deadline form takes what is left of one moment" {
    // docs/CANCEL.md, ruling A: the moment is absolute on the host's
    // monotonic clock — `os.deadline(ms)` builds it, `stop.expires`
    // crosses the language boundary as a scalar, and a moment already
    // passed is a poll answering absence, never a wait.
    try agree.prints(
        \\import std.os
        \\
        \\func feed(outbox: channel[i64]):
        \\    outbox.send(42) catch reason:
        \\        print(reason)
        \\
        \\func main() -> !:
        \\    var inbox = channel[i64](4)
        \\    let t = spawn feed(inbox)
        \\    let stop = os.deadline(4000)
        \\    print(str((try inbox.receive_by(stop.expires)) else -1))
        \\    t.wait()
        \\    var empty = channel[i64](4)
        \\    let lapsed = os.deadline(0)
        \\    print(str((try empty.receive_by(lapsed.expires)) else -1))
        \\
    ,
        \\42
        \\-1
        \\
    );
}

test "receive_by: a closed channel answers the error, drained first" {
    try agree.prints(
        \\import std.os
        \\
        \\func main() -> !:
        \\    var c = channel[i64](4)
        \\    try c.send(7)
        \\    c.close()
        \\    let stop = os.deadline(4000)
        \\    print(str((try c.receive_by(stop.expires)) else -1))
        \\    var said = ""
        \\    var landed: i64? = none
        \\    landed = c.receive_by(stop.expires) catch reason:
        \\        said = reason
        \\    print(said)
        \\
    ,
        \\7
        \\the channel is closed
        \\
    );
}
