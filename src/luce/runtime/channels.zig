//! Channels — the one reference that crosses workers.
//!
//! A channel is a global row no runtime owns: a mutex, two conditions,
//! a bounded queue of parked value graphs, a closed flag, and a count
//! of the per-runtime wrapper objects holding it.  `send` deep-copies
//! the value into the registry's parking runtime and parks it;
//! `receive` unparks and deep-copies into the receiver — the same
//! boundary copy `spawn` arguments make, so no object identity ever
//! crosses and mutating a value after sending it is always safe.
//!
//! The registry is created with the entry runtime and shared by
//! pointer into every worker, exactly as the worker channel itself is.
//! Its parking runtime is opened lazily through the shared nursery —
//! the same door worker runtimes come through — and every copy in or
//! out of parking holds the registry's parking guard: one global lock
//! for copies (v1, documented), row locks only for the O(1) queue
//! moves.
//!
//! Close is idempotent news any holder may deliver.  A closed
//! channel's sends answer the closed error; receives drain what was
//! parked first and only then answer it — parked data is never lost
//! to a close.  The last wrapper release closes and frees the row:
//! a channel nobody holds could never be received from again.

const std = @import("std");
const builtin = @import("builtin");
const heap = @import("heap.zig");
const workers = @import("workers.zig");

const Lock = workers.Lock;

/// A blocking condition variable from the platform, `Lock`'s sibling
/// and for `Lock`'s reason: `libluce_rt` has no `Io` to lend
/// `std.Io.Cond`, and a spin here would burn a core per blocked
/// worker.  Zero-initialized on every arm, like the lock.
const Cond = if (builtin.os.tag == .windows) struct {
    handle: std.os.windows.CONDITION_VARIABLE = .{},

    fn wait(self: *Cond, guard: *Lock) void {
        _ = std.os.windows.ntdll.RtlSleepConditionVariableSRW(&self.handle, &guard.handle, null, 0);
    }
    fn timedWait(self: *Cond, guard: *Lock, timeout_ns: u64) void {
        var interval: std.os.windows.LARGE_INTEGER = -@as(i64, @intCast(timeout_ns / 100));
        _ = std.os.windows.ntdll.RtlSleepConditionVariableSRW(&self.handle, &guard.handle, &interval, 0);
    }
    fn signal(self: *Cond) void {
        std.os.windows.ntdll.RtlWakeConditionVariable(&self.handle);
    }
    fn broadcast(self: *Cond) void {
        std.os.windows.ntdll.RtlWakeAllConditionVariable(&self.handle);
    }
} else struct {
    handle: std.c.pthread_cond_t = .{},

    fn wait(self: *Cond, guard: *Lock) void {
        std.debug.assert(std.c.pthread_cond_wait(&self.handle, &guard.handle) == .SUCCESS);
    }
    fn timedWait(self: *Cond, guard: *Lock, timeout_ns: u64) void {
        var now: std.c.timespec = undefined;
        std.debug.assert(std.c.clock_gettime(.REALTIME, &now) == 0);
        const total: u64 = @as(u64, @intCast(now.nsec)) + timeout_ns;
        var until: std.c.timespec = .{
            .sec = now.sec + @as(isize, @intCast(total / std.time.ns_per_s)),
            .nsec = @intCast(total % std.time.ns_per_s),
        };
        // Timeout and spurious wake read the same to the caller: the
        // while-loop around every wait re-asks the condition.
        _ = std.c.pthread_cond_timedwait(&self.handle, &guard.handle, &until);
    }
    fn signal(self: *Cond) void {
        std.debug.assert(std.c.pthread_cond_signal(&self.handle) == .SUCCESS);
    }
    fn broadcast(self: *Cond) void {
        std.debug.assert(std.c.pthread_cond_broadcast(&self.handle) == .SUCCESS);
    }
};

const value_mod = @import("value.zig");

const Runtime = heap.Runtime;
const Value = value_mod.Value;
const Error = heap.Error;

pub const closed_message = "the channel is closed";

/// One parked value: the graph lives in the parking runtime, and this
/// is its root.
const Parked = struct { value: Value };

pub const Row = struct {
    guard: Lock = .{},
    not_empty: Cond = .{},
    not_full: Cond = .{},
    queue: std.ArrayList(Parked) = .empty,
    /// The first queued element, as an index into `queue` — a ring
    /// would save the memmove, but a channel queue is short (its
    /// capacity) and the copy per element dominates by orders.
    head: usize = 0,
    capacity: usize,
    closed: bool = false,
    /// How many wrapper objects across all runtimes hold this row.
    holders: usize = 1,

    fn length(self: *const Row) usize {
        return self.queue.items.len - self.head;
    }
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    guard: Lock = .{},
    rows: std.ArrayList(?*Row) = .empty,
    /// Serializes every copy into and out of parking, and guards the
    /// parking runtime's lazy open.
    parking_guard: Lock = .{},
    parking: ?*Runtime = null,
    /// How the parking runtime is returned when the registry dies.
    nursery: workers.Nursery = .{},

    pub fn create(gpa: std.mem.Allocator) std.mem.Allocator.Error!*Registry {
        const made = try gpa.create(Registry);
        made.* = .{ .gpa = gpa };
        return made;
    }

    pub fn destroy(self: *Registry) void {
        const gpa = self.gpa;
        for (self.rows.items) |held| {
            if (held) |row| {
                row.queue.deinit(gpa);
                gpa.destroy(row);
            }
        }
        self.rows.deinit(gpa);
        if (self.parking) |parked| {
            if (self.nursery.close) |shut| shut(self.nursery.context, parked);
        }
        gpa.destroy(self);
    }

    /// The parking runtime, opened through the nursery on first use.
    /// Called with `parking_guard` held.
    fn parkingRuntime(self: *Registry, asking: *Runtime) ?*Runtime {
        if (self.parking) |ready| return ready;
        const nursery = asking.nursery;
        // Parking wants only the open/close halves: `run` belongs to
        // spawning, and a program with channels but no workers still
        // parks.
        if (nursery.open == null or nursery.close == null) return null;
        const opened = nursery.open.?(nursery.context) orelse return null;
        opened.functions = asking.functions;
        self.nursery = .{ .context = nursery.context, .open = nursery.open, .close = nursery.close };
        self.parking = opened;
        return opened;
    }

    fn at(self: *Registry, id: i64) ?*Row {
        self.guard.lock();
        defer self.guard.unlock();
        if (id < 0 or id >= self.rows.items.len) return null;
        return self.rows.items[@intCast(id)];
    }
};

/// The registry this runtime shares, or the trap a world without one
/// answers.
fn registryOf(runtime: *Runtime) Error!*Registry {
    return runtime.channels orelse runtime.fail(.host_unavailable);
}

/// A fresh channel with `capacity` slots (at least one), as an owned
/// wrapper object in `runtime`.
pub fn make(runtime: *Runtime, capacity: i64) Error!Value {
    const registry = try registryOf(runtime);
    const row = registry.gpa.create(Row) catch return error.OutOfMemory;
    row.* = .{ .capacity = @intCast(@max(capacity, 1)) };
    registry.guard.lock();
    const id: i64 = @intCast(registry.rows.items.len);
    registry.rows.append(registry.gpa, row) catch {
        registry.guard.unlock();
        registry.gpa.destroy(row);
        return error.OutOfMemory;
    };
    registry.guard.unlock();
    return runtime.newChannel(id);
}

/// One more wrapper now holds `id` — a channel crossing a worker
/// boundary. Answers false for a row that is already gone, which a
/// live wrapper can never name.
pub fn retainRow(runtime: *Runtime, id: i64) bool {
    const registry = runtime.channels orelse return false;
    const row = registry.at(id) orelse return false;
    row.guard.lock();
    defer row.guard.unlock();
    row.holders += 1;
    return true;
}

/// A wrapper released: the last one closes the row and frees it.
pub fn releaseRow(runtime: *Runtime, id: i64) void {
    const registry = runtime.channels orelse return;
    const row = registry.at(id) orelse return;
    row.guard.lock();
    row.holders -= 1;
    const last = row.holders == 0;
    if (last) row.closed = true;
    row.not_empty.broadcast();
    row.not_full.broadcast();
    row.guard.unlock();
    if (!last) return;
    // Drain what was parked: those graphs live in the parking runtime
    // and nothing will ever receive them.
    registry.parking_guard.lock();
    defer registry.parking_guard.unlock();
    const parking = registry.parking orelse return freeRow(registry, id);
    row.guard.lock();
    while (row.head < row.queue.items.len) : (row.head += 1) {
        parking.freeValue(row.queue.items[row.head].value);
    }
    row.guard.unlock();
    freeRow(registry, id);
}

fn freeRow(registry: *Registry, id: i64) void {
    registry.guard.lock();
    defer registry.guard.unlock();
    if (registry.rows.items[@intCast(id)]) |row| {
        row.queue.deinit(registry.gpa);
        registry.gpa.destroy(row);
        registry.rows.items[@intCast(id)] = null;
    }
}

/// What a send or receive came to: the value (receives), or the news
/// that the channel was closed — recoverable, never a trap.
pub const Outcome = union(enum) {
    value: Value,
    /// try_receive with nothing parked, receive_timeout that timed
    /// out, try_send against a full queue.
    nothing,
    closed,
};

/// Park a copy of `held`.  Blocks while the queue is full; `blocking`
/// false answers `.nothing` instead.
pub fn send(runtime: *Runtime, channel: Value, held: Value, blocking: bool) Error!Outcome {
    const registry = try registryOf(runtime);
    const id = try runtime.channelRow(channel);
    const row = registry.at(id) orelse return runtime.fail(.use_after_free);

    // The copy happens before the queue has room, deliberately: a big
    // graph copies without stalling the row, and an over-eager copy on
    // a channel that turns out closed is freed below.
    registry.parking_guard.lock();
    const parking = registry.parkingRuntime(runtime) orelse {
        registry.parking_guard.unlock();
        return runtime.fail(.host_unavailable);
    };
    const copied = parking.copyValuesFrom(runtime, &.{held}) catch |mistake| {
        registry.parking_guard.unlock();
        return switch (mistake) {
            error.OutOfMemory => error.OutOfMemory,
            error.Trap => error.Trap,
        };
    };
    const parked = Parked{ .value = copied[0] };
    parking.objects.free(copied);
    registry.parking_guard.unlock();

    row.guard.lock();
    while (!row.closed and row.length() >= row.capacity) {
        if (!blocking) {
            row.guard.unlock();
            discardParked(registry, parked);
            return .nothing;
        }
        row.not_full.wait(&row.guard);
    }
    if (row.closed) {
        row.guard.unlock();
        discardParked(registry, parked);
        return .closed;
    }
    row.queue.append(registry.gpa, parked) catch {
        row.guard.unlock();
        discardParked(registry, parked);
        return error.OutOfMemory;
    };
    row.not_empty.signal();
    row.guard.unlock();
    return .{ .value = Value.none };
}

fn discardParked(registry: *Registry, parked: Parked) void {
    registry.parking_guard.lock();
    defer registry.parking_guard.unlock();
    if (registry.parking) |parking| parking.freeValue(parked.value);
}

/// Unpark the oldest value into `runtime`.  `timeout_ms` under zero
/// blocks; zero or more waits at most that long and answers
/// `.nothing`; `blocking` false answers `.nothing` immediately when
/// the queue is empty.
pub fn receive(runtime: *Runtime, channel: Value, blocking: bool, timeout_ms: i64) Error!Outcome {
    const registry = try registryOf(runtime);
    const id = try runtime.channelRow(channel);
    const row = registry.at(id) orelse return runtime.fail(.use_after_free);

    row.guard.lock();
    while (row.length() == 0) {
        if (row.closed) {
            row.guard.unlock();
            return .closed;
        }
        if (!blocking) {
            row.guard.unlock();
            return .nothing;
        }
        if (timeout_ms >= 0) {
            const before = row.length();
            row.not_empty.timedWait(&row.guard, @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms);
            if (row.length() == before and !row.closed) {
                row.guard.unlock();
                return .nothing;
            }
        } else {
            row.not_empty.wait(&row.guard);
        }
    }
    const parked = row.queue.items[row.head];
    row.head += 1;
    // Compact once the head has crossed the whole allocation, so the
    // queue never grows beyond capacity slots plus history.
    if (row.head == row.queue.items.len) {
        row.queue.clearRetainingCapacity();
        row.head = 0;
    }
    row.not_full.signal();
    row.guard.unlock();

    registry.parking_guard.lock();
    const parking = registry.parking orelse {
        registry.parking_guard.unlock();
        return runtime.fail(.host_unavailable);
    };
    const landed = runtime.copyValuesFrom(parking, &.{parked.value}) catch |mistake| {
        registry.parking_guard.unlock();
        return switch (mistake) {
            error.OutOfMemory => error.OutOfMemory,
            error.Trap => error.Trap,
        };
    };
    parking.freeValue(parked.value);
    const answer = landed[0];
    runtime.objects.free(landed);
    registry.parking_guard.unlock();
    return .{ .value = answer };
}

/// Close: idempotent news any holder may deliver.  Parked values stay
/// receivable; blocked senders and receivers all wake.
pub fn close(runtime: *Runtime, channel: Value) Error!void {
    const registry = try registryOf(runtime);
    const id = try runtime.channelRow(channel);
    const row = registry.at(id) orelse return runtime.fail(.use_after_free);
    row.guard.lock();
    defer row.guard.unlock();
    row.closed = true;
    row.not_empty.broadcast();
    row.not_full.broadcast();
}

/// How many values are parked right now — a snapshot, stale the
/// moment it is read, which is the only thing a length can be.
pub fn length(runtime: *Runtime, channel: Value) Error!i64 {
    const registry = try registryOf(runtime);
    const id = try runtime.channelRow(channel);
    const row = registry.at(id) orelse return runtime.fail(.use_after_free);
    row.guard.lock();
    defer row.guard.unlock();
    return @intCast(row.length());
}

pub fn capacityOf(runtime: *Runtime, channel: Value) Error!i64 {
    const registry = try registryOf(runtime);
    const id = try runtime.channelRow(channel);
    const row = registry.at(id) orelse return runtime.fail(.use_after_free);
    return @intCast(row.capacity);
}
