//! Workers — a spawn is a second runtime on a thread (docs/THREADS.md).
//!
//! The load-bearing fact this file rests on is one the tree already
//! had: **the runtime is a parameter, not a global**.  Every run owns
//! its `Runtime` — its object table, its scope ownership, its string
//! storage, its trap channel — so several isolated runtimes in one
//! process is the existing shape and a worker's heap costs no new
//! mechanism.  Share-nothing is therefore structural rather than
//! enforced: a handle is an index into *one* table and a string's bytes
//! come from *one* allocator, so nothing allocated in one runtime is
//! even addressable from another (D1).
//!
//! Two channels meet here, and the split between them is the whole
//! architecture:
//!
//! * **`Channel` is the machine's.**  A host supplies threads and
//!   nothing else — start this C function on one, wait for it to end —
//!   which is why the two slots carry no Luce vocabulary at all and why
//!   `std.network`'s and every future host's would fit them unchanged.
//!   Appended fail-closed like every effect (D8).
//! * **`Nursery` is the engine's.**  What a runtime *is* and how one
//!   function is run in it is not something a machine can answer: the
//!   compiled arm hands over a generated trampoline and `luce_rt_open`,
//!   the oracle hands over a `Machine` and its own allocator, and the
//!   two are genuinely different answers to one question.  That is the
//!   only place in `libluce_rt` where the engines differ, and it is
//!   deliberately not on the host table, because a host is a machine
//!   and this is not machinery.
//!
//! Everything else is one implementation for both arms, which is what
//! makes the two-engine comparison worth anything: the argument
//! transfer, the join, the census roll-up, the trap and error
//! adoption, and the effect lock are all here and are called by both.
//!
//! **The effect lock is here rather than in the hosts** (D9).  Host
//! services are called from one thread at a time, so `print` from three
//! workers is line-atomic and no host implementation needs to be
//! thread-safe — and a program that never spawns never allocates the
//! lock, never touches it, and pays nothing (D11).

const builtin = @import("builtin");
const std = @import("std");
const heap = @import("heap.zig");
const trace = @import("trace.zig");
const value = @import("value.zig");

const Runtime = heap.Runtime;
const Value = value.Value;

// ---------------------------------------------------------------------------
// What crosses the C boundary
// ---------------------------------------------------------------------------

/// The three answers a fallible service gives, as plain `i32`s.
///
/// Spelled here rather than reused from `08_llvm/abi.zig` for the
/// reason `files.zig` spells them: `runtime.zig` is the library the
/// backend generates calls *into*, and it must not import a compiler
/// stage to name a number.  The numbers are the same three.
pub const yes: i32 = 1;
pub const no: i32 = 0;
pub const exhausted: i32 = -1;

/// How a run of a Luce function ended, as `Nursery.run` answers it.
/// The same three numbers generated code passes around for a call's
/// outcome, and for the same reason: a worker *is* a call, made
/// somewhere else.
pub const survived: i32 = 0;
pub const raised_trap: i32 = 1;
pub const raised_error: i32 = 2;

/// What a host runs on a thread.  One C function, one opaque argument,
/// no return: everything a worker produces it writes into the block the
/// argument points at, because a thread's answer has to outlive the
/// thread.
pub const Body = *const fn (argument: ?*anyopaque) callconv(.c) void;

/// Start `body` on a thread of its own, answering the number the host
/// will know it by.  `yes` and the handle, or `no` and nothing.
pub const SpawnFn = *const fn (
    context: ?*anyopaque,
    body: Body,
    argument: ?*anyopaque,
    thread: *i64,
) callconv(.c) i32;

/// Wait for a thread to end.  Only `yes` means that the thread was joined;
/// every other answer means that the host cannot complete the join.  The
/// runtime turns that answer into `host_unavailable` for an observing
/// `wait`.  A non-observing release still has to finish the worker under the
/// host contract that a failed join has already lost the thread.
pub const JoinFn = *const fn (context: ?*anyopaque, thread: i64) callconv(.c) i32;

/// The host's half: threads, and nothing else (D8).
pub const Channel = struct {
    context: ?*anyopaque = null,
    spawn: ?SpawnFn = null,
    join: ?JoinFn = null,

    /// Both slots, or neither.  A host that can start a thread but not
    /// wait for one cannot honour D5, so it is not a host that threads.
    pub fn available(self: Channel) bool {
        return self.spawn != null and self.join != null;
    }
};

/// A fresh, empty runtime for a worker, or null when there is no
/// memory for one.
pub const OpenFn = *const fn (context: ?*anyopaque) callconv(.c) ?*Runtime;

/// Give a worker's runtime back.  Everything still alive in it goes
/// with it — which is what makes a worker's heap dying whole cost
/// nothing.
pub const CloseFn = *const fn (context: ?*anyopaque, worker: *Runtime) callconv(.c) void;

/// Run function `function` in `worker`, with `arguments` already
/// transferred into it, and leave the answer in `out`.  Answers
/// `survived`, `raised_trap` or `raised_error`; a trap's words and
/// frames, an error's words and origin, and a chosen exit status are
/// all left in the worker's own `Runtime`, where the join reads them.
/// If the worker exhausts its arena, it answers `raised_trap` with
/// `Runtime.exhausted` set; the join turns that marker back into
/// `error.OutOfMemory` rather than inventing a Luce trap.
///
/// `depth` is a **fresh** budget, not what is left of the spawner's
/// (D1): a worker's frames are its own thread's, so the number it
/// starts from is the number every run starts from.
pub const RunFn = *const fn (
    context: ?*anyopaque,
    worker: *Runtime,
    function: i64,
    arguments: [*]const Value,
    count: i64,
    out: *Value,
    depth: i64,
) callconv(.c) i32;

/// The value a spawn callback must replace when it answers `yes`.  Keeping a
/// sentinel in the output slot also lets rollback detect a malformed callback
/// that published a thread handle while answering `no` or another invalid
/// value, so it can join that thread before closing the child runtime.
const no_thread = std.math.minInt(i64);

/// The engine's half: a runtime, and what to run in one.
pub const Nursery = struct {
    context: ?*anyopaque = null,
    open: ?OpenFn = null,
    close: ?CloseFn = null,
    run: ?RunFn = null,

    pub fn available(self: Nursery) bool {
        return self.open != null and self.close != null and self.run != null;
    }
};

// ---------------------------------------------------------------------------
// The effect lock
// ---------------------------------------------------------------------------

/// A blocking mutex, taken from the platform rather than built here.
///
/// **`std.Thread` has no mutex in Zig 0.16 and `std.Io.Mutex` needs an
/// `Io`, which `libluce_rt` does not have and must not acquire** — the
/// library is a C ABI over Luce's semantics, and an `Io` is a caller's
/// object.  So the platform's own lock is used directly: the one thing
/// this must not be is a spin, because the lock is held across
/// `read_line` and `key_read`, which block for a person.
///
/// Zero-initialized on every arm: `pthread_mutex_t`'s default *is*
/// `PTHREAD_MUTEX_INITIALIZER` (macOS's signature field included), and
/// an SRWLOCK's is `SRWLOCK_INIT`.
const Lock = if (builtin.os.tag == .windows) struct {
    handle: std.os.windows.SRWLOCK = .{},

    fn lock(self: *Lock) void {
        std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.handle);
    }
    fn unlock(self: *Lock) void {
        std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.handle);
    }
    fn tryLock(self: *Lock) bool {
        return std.os.windows.ntdll.RtlTryAcquireSRWLockExclusive(&self.handle) != 0;
    }
} else struct {
    handle: std.c.pthread_mutex_t = .{},

    fn lock(self: *Lock) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.handle) == .SUCCESS);
    }
    fn unlock(self: *Lock) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.handle) == .SUCCESS);
    }
    fn tryLock(self: *Lock) bool {
        return std.c.pthread_mutex_trylock(&self.handle) == .SUCCESS;
    }
};

/// The one lock every runtime in a program shares (D9).
///
/// **Recursive on purpose.**  Effects nest: `f.read(buffer)` is a
/// `libluce_rt` call that reaches a host slot, and a coarser guard
/// higher up would deadlock a plain mutex at the inner one.  Making
/// re-entry free removes that whole class of bug for a handful of
/// instructions, and those instructions are only ever executed by a
/// program that has spawned — which is the one paying for them.
///
/// The thread id is atomic because a thread that does not hold the lock
/// reads it; `depth` is not, because only the holder ever touches it.
pub const Effects = struct {
    mutex: Lock = .{},
    owner: std.atomic.Value(usize) = .init(nobody),
    depth: u32 = 0,

    /// No thread's id, so an unheld lock is never mistaken for one this
    /// thread holds.
    const nobody: usize = std.math.maxInt(usize);

    fn me() usize {
        return @intCast(std.Thread.getCurrentId());
    }

    pub fn enter(self: *Effects) void {
        const self_id = me();
        if (self.owner.load(.acquire) == self_id) {
            self.depth += 1;
            return;
        }
        self.mutex.lock();
        self.owner.store(self_id, .release);
        self.depth = 1;
    }

    pub fn leave(self: *Effects) void {
        // This is also a public runtime door.  Generated code balances its
        // own pairs, but a damaged artifact or a hostile callback must not
        // be able to decrement another thread's recursion depth or unlock
        // the platform mutex from the wrong thread.  Check ownership before
        // touching `depth`; reading it from a non-holder would itself be a
        // data race.
        if (self.owner.load(.acquire) != me()) return;
        if (self.depth == 0) return;
        self.depth -= 1;
        if (self.depth != 0) return;
        self.owner.store(nobody, .release);
        self.mutex.unlock();
    }
};

// ---------------------------------------------------------------------------
// A worker
// ---------------------------------------------------------------------------

/// One running worker: its runtime, the call it is making, and where
/// the answer lands.
///
/// Heap-allocated by the runtime that spawned it and pointed at by
/// exactly one `task` object, which is what makes "one worker, one
/// owner" true by construction rather than by rule.
pub const Worker = struct {
    /// The worker's own runtime (D1), null once joined and closed.
    runtime: ?*Runtime,
    /// Copies rather than pointers into the spawner: a worker outlives
    /// nothing it reads here, and copying two small structs at a spawn
    /// is cheaper than keeping a runtime pointer valid across a join.
    nursery: Nursery,
    channel: Channel,
    /// What the host calls the thread; meaningless unless `running`.
    thread: i64 = no_thread,
    running: bool = false,
    function: i64,
    depth: i64,
    /// The arguments, already re-owned into `runtime`.  The array is
    /// the worker's runtime's; the values in it are too.
    arguments: []Value,
    outcome: i32 = survived,
    result: Value = .none,
};

/// The one thing a worker thread does.
fn body(argument: ?*anyopaque) callconv(.c) void {
    const worker: *Worker = @ptrCast(@alignCast(argument.?));
    const child = worker.runtime.?;
    const run = worker.nursery.run.?;
    worker.outcome = run(
        worker.nursery.context,
        child,
        worker.function,
        worker.arguments.ptr,
        @intCast(worker.arguments.len),
        &worker.result,
        worker.depth,
    );
    if (worker.outcome != survived and
        worker.outcome != raised_trap and
        worker.outcome != raised_error)
    {
        // A nursery is an engine-owned callback, but decoded or hostile
        // callers can still violate its plain-number contract.  Do not let
        // an unknown answer fall through to `wait` as a successful result;
        // release any provisional answer under the child runtime and carry
        // one ordinary host-boundary trap instead.
        child.freeValue(worker.result);
        worker.result = .none;
        worker.outcome = raised_trap;
        _ = child.fail(.host_unavailable) catch {};
    }
    if (worker.outcome != survived) return;
    // **The join is the caller, and this is the caller's first step.**
    //
    // A returned value's storage is the caller's to keep, and a caller
    // takes it by copying — the `own_storage` stage 4 puts in front of
    // the store — and then releases what it was handed, because a
    // `ret` moves the storage out of the frame rather than lending it
    // (docs/STRINGS.md).  A worker has no caller standing at its `ret`,
    // so the two steps are taken here, on the worker's own thread and
    // in the worker's own runtime.
    //
    // Doing it here rather than at the join is what makes the join
    // simple: after this the answer is unambiguously this runtime's,
    // so `wait` can move it across and `finish` can release it without
    // either of them having to know where the bytes came from.
    const answered = worker.result;
    worker.result = child.ownValue(answered) catch |mistake| taken: {
        // No memory to take the copy with: this is ordinary run
        // exhaustion, not a located Luce allocation trap.  The copy may
        // have been a struct whose fields include object rows, so release
        // the complete answer rather than only its value-storage bytes.
        switch (mistake) {
            error.OutOfMemory => child.exhausted = true,
            error.Trap => {},
        }
        worker.outcome = raised_trap;
        break :taken .none;
    };
    if (worker.result.isNone()) {
        child.freeValue(answered);
    } else {
        child.dropStorage(answered);
    }
}

// ---------------------------------------------------------------------------
// spawn
// ---------------------------------------------------------------------------

/// `spawn f(args)` — open a runtime for the worker, move the arguments
/// into it, start the thread, and answer the task that owns it (D2, D3).
///
/// **Everything that can fail happens on this thread, before the
/// thread starts.**  A runtime that could not be opened, an argument
/// that could not be carried across, a host that does not thread: all
/// of them are a trap at the `spawn`, located and traced like every
/// other, rather than a failure with nobody standing at it.
pub fn spawn(
    parent: *Runtime,
    function: i64,
    arguments: []const Value,
    out: *Value,
) heap.Error!void {
    const channel = parent.workers;
    const nursery = parent.nursery;
    if (!channel.available() or !nursery.available()) return parent.fail(.host_unavailable);
    // These values cross the public C door as signed integers.  A negative
    // function would reach an engine-specific cast, and an invalid depth
    // would do the same in the interpreter; reject both before allocating a
    // worker or moving an argument.
    if (function < 0 or std.math.cast(u32, parent.depth_budget) == null) {
        return parent.fail(.host_unavailable);
    }

    const effects = try parent.sharedEffects();

    const worker = try parent.objects.create(Worker);
    errdefer parent.objects.destroy(worker);

    const child = nursery.open.?(nursery.context) orelse return parent.fail(.allocation_failed);
    errdefer nursery.close.?(nursery.context, child);

    // What a worker inherits is everything about the *run* — the
    // artifact's function table, the host's channels, the shared lock —
    // and nothing about the *thread*.  Its heap, its scopes and its
    // depth budget are its own, which is the whole of D1.
    child.functions = parent.functions;
    child.files = parent.files;
    child.workers = parent.workers;
    child.nursery = parent.nursery;
    child.effects = effects;
    child.depth_budget = parent.depth_budget;

    const moved = try child.objects.alloc(Value, arguments.len);
    var carried: usize = 0;
    errdefer {
        // The worker frame borrows these values from this array.  On a
        // failed spawn there is no frame left to return that storage to,
        // while any object rows are reclaimed by the child Runtime's
        // closing sweep just below.
        for (moved[0..carried]) |argument| child.dropStorage(argument);
        child.objects.free(moved);
    }
    while (carried < arguments.len) : (carried += 1) {
        moved[carried] = try parent.moveInto(child, arguments[carried]);
    }

    worker.* = .{
        .runtime = child,
        .nursery = nursery,
        .channel = channel,
        .function = function,
        .depth = parent.depth_budget,
        .arguments = moved,
    };

    const spawn_answer = channel.spawn.?(channel.context, body, worker, &worker.thread);
    if (spawn_answer != yes) {
        // A well-behaved failed callback leaves the handle at `no_thread`.
        // If it nevertheless published one, it has handed us evidence that
        // a thread exists; join it before the child runtime is closed.  This
        // keeps malformed host behavior from turning the child into a
        // use-after-close race.
        if (worker.thread != no_thread) {
            worker.running = true;
            _ = joinThread(worker);
        }
        // A malformed callback may have run the body synchronously before
        // answering failure.  The result is not rooted in the child heap,
        // so child.deinit() cannot discover its standalone storage; discard
        // it explicitly before the errdefer closes that runtime.
        child.freeValue(worker.result);
        worker.result = .none;
        return parent.fail(.host_unavailable);
    }
    if (worker.thread == no_thread) {
        child.freeValue(worker.result);
        worker.result = .none;
        return parent.fail(.host_unavailable);
    }
    worker.running = true;

    // The thread is away; from here the worker must be joined whatever
    // happens, so the one remaining failure joins it by hand rather
    // than leaving an orphan the errdefers above cannot reach.
    const task = parent.newTask(worker) catch |mistake| {
        _ = joinThread(worker);
        // `body` made a successful result this runtime's own.  The task
        // row could not be allocated, so no later `wait`/`release` can
        // perform `finish` and this is its only remaining death point.
        child.freeValue(worker.result);
        worker.result = .none;
        return mistake;
    };
    out.* = task;
}

// ---------------------------------------------------------------------------
// wait, and the two other ways a task ends
// ---------------------------------------------------------------------------

/// `t.wait()` — join the worker and move its result here, once (D4).
///
/// Answers `survived` or `raised_error`; a trap in the worker is a trap
/// here, raised with the worker's own frames in front of this frame's
/// (D6), and a worker that said `exit(status)` stops the program at the
/// join carrying the status it chose.
///
/// The task is **consumed**: its worker is detached before anything
/// that can fail, so no path can join twice.  Stage 4 refuses a second
/// wait the way it refuses a second `give`; this is the wall behind it.
pub fn wait(joiner: *Runtime, task: Value, out: *Value) heap.Error!i32 {
    const worker = try take(joiner, task);
    const child = worker.runtime.?;
    // The task is detached before any result, trap, or error is adopted.
    // Adoption can allocate in the joiner's arena (notably for a worker
    // error's message), so cleanup must not depend on the adoption
    // succeeding.  A failed adoption still owns the child runtime, the
    // argument block, and the worker record until this scope ends.
    defer finish(joiner, worker);

    // A task cannot be reported as successfully waited when the host did
    // not answer the join with the one success code.  The task was already
    // consumed by `take`, and `finish` below still closes the child under
    // the host callback's lost-thread contract.
    if (!joinThread(worker)) return joiner.fail(.host_unavailable);

    if (child.exit_status) |chosen| {
        // The program chose to stop, in a thread that is not the one
        // `main` is on.  It stops here, at the join, carrying the
        // status it chose — the same edge a trap rides, for the same
        // reason: there is exactly one place a worker's ending can be
        // spoken, and this is it.
        joiner.exit_status = chosen;
        return error.Trap;
    }
    if (worker.outcome == raised_trap) {
        return adoptTrap(joiner, child);
    }
    if (worker.outcome == raised_error) {
        try adoptError(joiner, child);
        return raised_error;
    }

    out.* = try joiner.copyFrom(child, worker.result);
    return survived;
}

/// Releasing a task is a join (D5): `free(t)`, the end of the scope
/// that owns it, and the run's own sweep of what a program leaked all
/// arrive here.  There is no way to own a running worker and not wait
/// for it, which is what makes an orphan thread as unrepresentable as
/// a leaked list.
///
/// **A release observes nothing.**  The result is discarded, and so is
/// a trap the worker raised — because the ownership walk is total and
/// must stay total: it runs inside `freeObject`, from a scope's end,
/// from an unwind that is already carrying a trap, and from the sweep
/// at the end of a run, and not one of those three has anybody to
/// report a second trap to.  So there is one rule and it is the simple
/// one: **only a `wait` observes**.  A program that wants a worker's
/// trap to stop it waits for the worker.
pub fn release(owner: *Runtime, worker: *Worker) void {
    _ = joinThread(worker);
    finish(owner, worker);
}

/// Detach the worker a task owns, or trap if there is none left.
fn take(joiner: *Runtime, task: Value) heap.Error!*Worker {
    const object = try joiner.resolveMutable(task);
    switch (object.data) {
        .task => |held| {
            const worker = held orelse return joiner.fail(.use_after_free);
            object.data = .{ .task = null };
            return worker;
        },
        // The verifier admits only a task here; IR that arrived some
        // other way is refused rather than reinterpreted.
        .list, .map, .array, .builder, .file => return joiner.fail(.not_owned),
    }
}

fn joinThread(worker: *Worker) bool {
    if (!worker.running) return true;
    worker.running = false;
    const join = worker.channel.join orelse return false;
    return join(worker.channel.context, worker.thread) == yes;
}

/// Give the worker's runtime and its own block back.  The caller has
/// already joined the thread and taken whatever it wanted out.
fn finish(owner: *Runtime, worker: *Worker) void {
    const child = worker.runtime.?;
    // A parameter *borrows* its caller's storage (`mir.Local`), and
    // here the caller is this array: the callee's frame never owned the
    // bytes a `string` argument arrived in, so they go back with the
    // frame that did.  An object argument's handle is stale by now and
    // `dropStorage` leaves objects alone, which is exactly right — the
    // `give` parameter that received it freed it at its own scope's end.
    for (worker.arguments) |argument| child.dropStorage(argument);
    child.objects.free(worker.arguments);
    // And the worker's own answer, which the join has already copied
    // across or deliberately discarded.
    //
    // **What is released here is what a `ret` owns, and no more.**  A
    // returned value's storage is the caller's, and the caller here is
    // the join — but "the caller's" is not the same as "an allocation":
    // a returned `string` may be a borrow of a program constant, which
    // owns nothing and must not be freed, and only the IR knows which
    // (docs/STRINGS.md).  What is *always* an allocation is a struct's
    // field run, which `struct_make` built and consumed its fields
    // into, and the objects the answer holds, which are rows of this
    // table.  So those two go back and the bytes do not: releasing a
    // constant would be a free of the artifact's own data, and holding
    // a run would be a leak the census could not see.
    // `body` has already made the answer this runtime's own (see
    // there), so it is released here without qualification: the join
    // has taken its copy, or has deliberately discarded the answer, and
    // either way this is its death point.
    child.freeValue(worker.result);
    worker.result = .none;
    // The census last, once nothing of this worker's is still standing
    // that ownership was going to release: what is left is what the
    // program leaked, and it is this program's leak however many
    // runtimes it used (D10).
    owner.inherited_leaks += child.leaked();
    worker.nursery.close.?(worker.nursery.context, child);
    worker.runtime = null;
    owner.objects.destroy(worker);
}

/// Carry the worker's trap across the join, with its frames in front
/// of this frame's (D6).
///
/// The words cross by copy — `joiner.failMessage` takes it, while the
/// child's arena is still open, because `finish` has not run yet —
/// since a `trap("…")`'s message is the worker's own and dies with its
/// runtime.  The frames are not copied and do not need to be: a frame
/// names a function and a file out of the *program*, which outlives
/// every runtime in it.
fn adoptTrap(joiner: *Runtime, child: *Runtime) heap.Error {
    // Exhaustion is carried out-of-band because there is no Luce trap to
    // adopt.  It must be checked before `pending`: an allocator failure
    // while a worker is unwinding is still an exhausted run, not a
    // host-unavailable trap fabricated by the join.
    if (child.exhausted) return error.OutOfMemory;
    const pending = child.pending orelse
        return joiner.fail(.host_unavailable); // a trapped worker with no trap
    joiner.unwound.appendSlice(joiner.objects, child.unwound.items) catch {
        joiner.dropped_frames +|= @intCast(child.unwound.items.len);
    };
    joiner.dropped_frames +|= child.dropped_frames;
    return joiner.failMessage(pending.code, pending.message);
}

/// Carry the worker's raised error across the join, whole: the code,
/// the words, and the one place it was raised (D4).
fn adoptError(joiner: *Runtime, child: *Runtime) heap.Error!void {
    const raised = child.raised orelse return joiner.fail(.host_unavailable);
    const words = try joiner.arena.dupe(u8, raised.message);
    joiner.raised = .{
        .code = raised.code,
        .message = words,
        .origin = raised.origin,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the effect lock is recursive on its holder and exclusive of everyone else" {
    var effects: Effects = .{};
    effects.enter();
    effects.enter();
    try std.testing.expectEqual(@as(u32, 2), effects.depth);
    effects.leave();
    try std.testing.expectEqual(@as(u32, 1), effects.depth);
    effects.leave();
    try std.testing.expectEqual(Effects.nobody, effects.owner.load(.acquire));
    // Unheld again, so anybody may take it.
    try std.testing.expect(effects.mutex.tryLock());
    effects.mutex.unlock();
}

test "an unmatched effect release cannot underflow or unlock another thread" {
    var effects: Effects = .{};

    // A release before any acquire is a malformed boundary call and must be
    // inert rather than wrapping the recursion depth in a debug build.
    effects.leave();
    try std.testing.expectEqual(@as(u32, 0), effects.depth);
    try std.testing.expectEqual(Effects.nobody, effects.owner.load(.acquire));

    effects.enter();
    try std.testing.expectEqual(@as(u32, 1), effects.depth);
    const Foreign = struct {
        fn leave(held: *Effects) void {
            held.leave();
        }
    };
    const foreign = try std.Thread.spawn(.{}, Foreign.leave, .{&effects});
    foreign.join();
    try std.testing.expectEqual(@as(u32, 1), effects.depth);
    try std.testing.expect(effects.owner.load(.acquire) != Effects.nobody);
    effects.leave();
    effects.leave();
    try std.testing.expectEqual(@as(u32, 0), effects.depth);
    try std.testing.expectEqual(Effects.nobody, effects.owner.load(.acquire));
}

test "a channel and a nursery are available only when every slot is filled" {
    // Real functions rather than `undefined`, so what is under test is
    // "is the slot filled" and not the optimizer's opinion of an
    // undefined pointer.  None of them is called.
    const Stubs = struct {
        fn spawn(_: ?*anyopaque, _: Body, _: ?*anyopaque, _: *i64) callconv(.c) i32 {
            return no;
        }
        fn join(_: ?*anyopaque, _: i64) callconv(.c) i32 {
            return no;
        }
        fn open(_: ?*anyopaque) callconv(.c) ?*Runtime {
            return null;
        }
        fn close(_: ?*anyopaque, _: *Runtime) callconv(.c) void {}
        fn run(
            _: ?*anyopaque,
            _: *Runtime,
            _: i64,
            _: [*]const Value,
            _: i64,
            _: *Value,
            _: i64,
        ) callconv(.c) i32 {
            return raised_trap;
        }
    };

    const empty: Channel = .{};
    try std.testing.expect(!empty.available());
    const half: Channel = .{ .spawn = Stubs.spawn };
    try std.testing.expect(!half.available());
    const whole: Channel = .{ .spawn = Stubs.spawn, .join = Stubs.join };
    try std.testing.expect(whole.available());

    const bare: Nursery = .{};
    try std.testing.expect(!bare.available());
    const partial: Nursery = .{ .open = Stubs.open, .close = Stubs.close };
    try std.testing.expect(!partial.available());
    const full: Nursery = .{ .open = Stubs.open, .close = Stubs.close, .run = Stubs.run };
    try std.testing.expect(full.available());
}

test "worker leak folding excludes the child runtime's program roots" {
    const Close = struct {
        fn close(_: ?*anyopaque, runtime: *Runtime) callconv(.c) void {
            runtime.deinit();
        }
    };

    var parent_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer parent_arena.deinit();
    var child_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer child_arena.deinit();
    var parent: Runtime = .init(.{
        .arena = parent_arena.allocator(),
        .objects = std.testing.allocator,
    });
    defer parent.deinit();
    var child: Runtime = .init(.{
        .arena = child_arena.allocator(),
        .objects = std.testing.allocator,
    });

    try child.beginConstants(1);
    const rooted = try child.newList(Value.ofLong(0));
    try child.publishConstant(0, rooted);
    child.finishConstants();
    _ = try child.newList(Value.ofLong(0));
    try std.testing.expectEqual(@as(i64, 1), child.leaked());

    const arguments = try child.objects.alloc(Value, 1);
    arguments[0] = .none;
    const worker = try parent.objects.create(Worker);
    worker.* = .{
        .runtime = &child,
        .nursery = .{ .close = Close.close },
        .channel = .{},
        .function = 0,
        .depth = 0,
        .arguments = arguments,
    };
    finish(&parent, worker);

    try std.testing.expectEqual(@as(i64, 1), parent.inherited_leaks);
    try std.testing.expectEqual(@as(i64, 1), parent.leaked());
}

test "the three outcome numbers are the ones generated code passes around" {
    try std.testing.expectEqual(@as(i32, 0), survived);
    try std.testing.expectEqual(@as(i32, 1), raised_trap);
    try std.testing.expectEqual(@as(i32, 2), raised_error);
}

comptime {
    _ = trace;
}
