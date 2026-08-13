//! The two test hosts, and the world they present.
//!
//! A spec runs its program twice against one world (`agree.zig`), and
//! the two runs reach that world through different doors: the oracle
//! calls `interpreter.Host`, an ordinary Zig vtable, and the compiled
//! program calls `LuceHost`, the published C ABI, from inside a
//! `dlopen`ed library.  `Reference` is the first door and `Capture`
//! the second.  They are written side by side, in one file, for the
//! same reason `World` is written once: a difference between them
//! would look exactly like the lowering bug the comparison exists to
//! find, so there must be nowhere for one to hide.
//!
//! Nothing here allocates on behalf of a `Capture` callback.  Those
//! callbacks are entered from compiled machine code, and
//! `std.testing.allocator` captures a stack trace on every allocation:
//! the unwinder cannot walk back through the compiled program's frame
//! and faults inside the panic handler.  Every buffer in `Capture` is
//! therefore fixed, deliberately — and a fixed buffer that fills up
//! says so, in the buffer (`keepText`).
//!
//! `agree.zig` re-exports all four names, so a spec never imports this
//! file: the harness is one door, and this is what is behind it.

const std = @import("std");

const luce = @import("luce");

const interpreter = luce.interpreter;
const mir = luce.mir;
const abi = luce.llvm.abi;
const runtime = luce.runtime;

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// How many workers one spec may have running at once.  A `Capture` is
/// fixed buffers throughout (see the header), and a spec that wants
/// more threads than this is a spec about something other than the
/// language.
const max_worker_threads = 16;

// ---------------------------------------------------------------------------
// The world both hosts present
// ---------------------------------------------------------------------------

/// What the two hosts below offer a program: one in-memory file, an
/// argument list, a screen that records instead of drawing, a scripted
/// keyboard, and scripted standard input.
///
/// Written once and shared, so the interpreter's host and the compiled
/// program's host cannot differ in *what* they offer — only in how they
/// are called.  A disagreement is then a lowering bug, which is the
/// only thing these comparisons are trying to find.
///
/// Each arm gets its own copy, so a program that writes a file cannot
/// leave the second run a world the first one changed.
pub const World = struct {
    file_name: [64]u8 = undefined,
    file_name_length: usize = 0,
    file_content: [1024]u8 = undefined,
    file_content_length: usize = 0,
    /// A world that will not take a write, which is the `io_failed`
    /// side of a fallible effect (docs/FAILURE.md).
    refuse_writes: bool = false,
    /// The command line this world was started with.
    arguments: []const []const u8 = &default_arguments,
    /// The keys the program will read.  The script does **not**
    /// repeat: running off the end is end of input, which is the case
    /// `key_read`'s `string?` exists for, and a repeating keyboard is
    /// one no test can ever reach the end of.
    keys: []const Key = &default_keys,
    /// How many keys the program has read.
    keys_read: usize = 0,
    /// Data belonging to the most recently returned terminal event.  The
    /// number-only event query reads this after `key_read`, just as the real
    /// host reads its screen's last event.
    last_event: Key = .{ .name = "" },
    /// The lines standard input will answer.  The script does *not*
    /// repeat: running off the end is end of input, which is the case
    /// a `string?` exists for.
    lines: []const []const u8 = &default_lines,
    /// How many lines of standard input have been taken.
    lines_read: usize = 0,
    /// The one directory this world will list, or null for a world
    /// whose listing fails.
    directory: ?[]const []const u8 = &default_directory,
    /// What this world says is at each path, beyond the things it
    /// already knows about — its one file, the directories it was made
    /// to hold, and the directory it lists.  A script rather than a
    /// simulated file system, for `clock`'s reason: what is under test
    /// is that the four codes cross both host tables intact, not that
    /// this file is a model of a disk.
    kinds: []const KindRow = &default_kinds,
    /// The paths this world will not answer *about* — the memo's
    /// measured case, a `chmod 000` parent.  A prefix match, because
    /// that is how a refused directory behaves: nothing under it can
    /// be reached either.  `path_kind` answers `no`, which the program
    /// meets as `io_failed` and never as "nothing is there".
    refused_kinds: []const []const u8 = &.{},
    /// That listing, NUL-joined — the shape a compiled program takes
    /// it in.  Built from `directory` on demand rather than declared,
    /// so the two hosts can never say different things.
    joined_storage: [1024]u8 = undefined,
    joined_length: usize = 0,
    /// A clock that ticks a fixed amount per reading rather than a
    /// real one.  Two engines cannot agree on a wall clock, and what
    /// is under test is the marshalling, not the calendar.
    clock: i64 = 1_000,
    /// The wall clock, on the same terms and for the same reason: a
    /// plausible number of milliseconds since the Unix epoch, ticking
    /// a fixed step per reading so two engines reading it twice each
    /// still agree.  A spec proves that the reading crosses both host
    /// tables intact and never goes backwards; what the real calendar
    /// says is `apps/host.zig`'s business, and its own test's.
    epoch: i64 = 1_755_000_000_000,
    /// A world with no calendar: `epoch_ms` answers "cannot tell",
    /// which the program meets as `host_unavailable` — the refusal a
    /// null slot gives, arriving through a slot that is there.  The
    /// same distinction `unmeasurable` draws for the machine facts.
    timeless: bool = false,
    /// The directories this world has been made to hold, one full path
    /// per row.  A flat set rather than a tree: what a spec has to see
    /// is *which* directories a call left behind, and since
    /// `dir_create` makes the parents too, the set is the whole
    /// answer.
    made: [max_made_directories][64]u8 = undefined,
    made_lengths: [max_made_directories]usize = @splat(0),
    made_count: usize = 0,
    /// The machine this world claims to be, for the same reason the
    /// clock is not a real one: two engines cannot agree on what the
    /// real machine had free between the two runs, and what is under
    /// test is that the number crosses the boundary intact.
    ///
    /// A plausible machine — eight gibibytes, rather more than half of
    /// them spoken for — so a spec can assert the relations `std.os`
    /// promises (`available <= total`, `used = total - available`) on
    /// numbers a person can check by eye.
    total_memory: i64 = 8 * 1024 * 1024 * 1024,
    available_memory: i64 = 3 * 1024 * 1024 * 1024,
    cpu_count: i64 = 4,
    /// A deterministic transcript for the shell seam.  Specs do not
    /// launch a real process; they prove the call crosses both host
    /// tables and returns owned text.
    shell_output: [1024]u8 = undefined,
    shell_output_length: usize = 0,
    /// A machine this world cannot measure: every fact answers `no`,
    /// which is the host saying it cannot tell and the program meeting
    /// `host_unavailable` — the refusal a null slot gives, arriving
    /// through a slot that is there.
    unmeasurable: bool = false,
    /// The one handle this world will have open, or null when it has
    /// none.  Numbers never repeat, so a handle whose scope closed it
    /// is refused rather than mistaken for the next one — which is what
    /// lets a spec see that a close happened.
    open_handle: ?i64 = null,
    next_handle: i64 = 0,
    /// Where the open handle has read to, and whether it was opened
    /// for writing.
    handle_position: usize = 0,
    handle_writes: bool = false,

    pub const Key = struct {
        name: []const u8,
        text: []const u8 = "",
        row: i64 = 0,
        column: i64 = 0,
        button: i64 = -1,
        modifiers: i64 = 0,
        value: i64 = 0,
    };

    const rows: i64 = 24;
    const cols: i64 = 80;
    const clock_step: i64 = 17;
    /// The wall clock moves less per reading than the monotonic one,
    /// so a spec printing both cannot confuse which it is looking at.
    const epoch_step: i64 = 3;
    /// How many directories one world may hold.  A `Capture` is fixed
    /// buffers throughout (see the header), and a spec that wants a
    /// deeper tree than this is a spec about the file system.
    const max_made_directories = 16;

    /// One path and what is at it (`abi.PathKindFn`'s four codes,
    /// named).
    pub const KindRow = struct {
        path: []const u8,
        kind: enum(i64) { nothing = 0, file = 1, directory = 2, other = 3 },
    };

    const default_arguments = [_][]const u8{ "alpha", "beta" };
    const default_lines = [_][]const u8{ "first line", "second line" };
    const default_directory = [_][]const u8{ "alpha.txt", "beta.txt", "notes" };
    /// What the default listing's three names are, plus the directory
    /// they are in.  `notes` is a directory and the other two are
    /// files, so one listing carries two kinds and a walk written
    /// against it has both branches to take.
    const default_kinds = [_]KindRow{
        .{ .path = ".", .kind = .directory },
        .{ .path = "alpha.txt", .kind = .file },
        .{ .path = "beta.txt", .kind = .file },
        .{ .path = "notes", .kind = .directory },
    };
    const default_keys = [_]Key{
        .{ .name = "text", .text = "q" },
        .{ .name = "enter" },
        .{ .name = "ctrl_s" },
    };

    const environment = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "LUCE_MODE", .value = "test" },
        .{ .name = "EMPTY", .value = "" },
    };

    /// A world whose one file is already there.  The seed goes in
    /// under `refuse_writes`, because refusing a program's writes says
    /// nothing about what the world started with.
    pub fn withFile(path: []const u8, content: []const u8) World {
        var world: World = .{};
        world.place(path, content);
        return world;
    }

    /// Put a file there without asking the world's permission.
    pub fn place(self: *World, path: []const u8, content: []const u8) void {
        std.debug.assert(path.len != 0 and path.len <= self.file_name.len);
        std.debug.assert(content.len <= self.file_content.len);
        @memcpy(self.file_name[0..path.len], path);
        self.file_name_length = path.len;
        @memcpy(self.file_content[0..content.len], content);
        self.file_content_length = content.len;
    }

    fn variable(name: []const u8) ?[]const u8 {
        for (environment) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }

    fn nextLine(self: *World) ?[]const u8 {
        if (self.lines_read >= self.lines.len) return null;
        defer self.lines_read += 1;
        return self.lines[self.lines_read];
    }

    fn tick(self: *World) i64 {
        defer self.clock += clock_step;
        return self.clock;
    }

    /// What time this world says it is, or null for a world with no
    /// calendar at all.
    fn epochTick(self: *World) ?i64 {
        if (self.timeless) return null;
        defer self.epoch += epoch_step;
        return self.epoch;
    }

    // -- directories ---------------------------------------------------

    /// Make a directory and every directory leading to it, answering
    /// whether there is one there now (`abi.DirCreateFn`).
    ///
    /// The two rules the service publishes are kept here rather than
    /// asserted about: the parents are recorded alongside the leaf,
    /// and a directory already in the set is a plain `true`.  A world
    /// that refuses writes refuses this too, and the one *file* it
    /// holds standing in the way is a refusal of its own — the caller
    /// asked for a directory and there is not one.
    fn createDirectory(self: *World, path: []const u8) bool {
        const wanted = trimmedPath(path);
        if (wanted.len == 0) return false;
        if (self.refuse_writes) return false;
        var at: usize = 0;
        while (at < wanted.len) {
            const stop = std.mem.indexOfScalarPos(u8, wanted, at, '/') orelse wanted.len;
            const prefix = wanted[0..stop];
            if (self.exists(prefix)) return false;
            if (!self.hasDirectory(prefix)) {
                if (self.made_count == max_made_directories) return false;
                if (prefix.len > self.made[0].len) return false;
                @memcpy(self.made[self.made_count][0..prefix.len], prefix);
                self.made_lengths[self.made_count] = prefix.len;
                self.made_count += 1;
            }
            at = stop + 1;
        }
        return true;
    }

    /// Whether this world holds a directory of that name.
    fn hasDirectory(self: *const World, path: []const u8) bool {
        const wanted = trimmedPath(path);
        for (0..self.made_count) |row| {
            if (std.mem.eql(u8, self.made[row][0..self.made_lengths[row]], wanted)) return true;
        }
        return false;
    }

    /// How many directories this world holds.
    pub fn directoryCount(self: *const World) usize {
        return self.made_count;
    }

    /// One directory's name, borrowed from this world.
    pub fn directoryAt(self: *const World, row: usize) []const u8 {
        return self.made[row][0..self.made_lengths[row]];
    }

    /// A path without its trailing separator, so "papers/" and
    /// "papers" name the one directory they do on a real file system.
    fn trimmedPath(path: []const u8) []const u8 {
        var end = path.len;
        while (end != 0 and path[end - 1] == '/') end -= 1;
        return path[0..end];
    }

    /// The machine's three facts, or null for a world that cannot
    /// measure itself.  Fixed numbers rather than moving ones: the two
    /// engines run one after the other, and a fact that changed
    /// between them would be a disagreement about the machine rather
    /// than about the lowering.
    fn totalMemory(self: *World) ?i64 {
        return if (self.unmeasurable) null else self.total_memory;
    }

    fn availableMemory(self: *World) ?i64 {
        return if (self.unmeasurable) null else self.available_memory;
    }

    fn cpuCount(self: *World) ?i64 {
        return if (self.unmeasurable) null else self.cpu_count;
    }

    fn shellRun(self: *World, command: []const u8) ?[]const u8 {
        const rendered = std.fmt.bufPrint(
            &self.shell_output,
            "mock shell: {s}\nexit status: 0\n",
            .{command},
        ) catch return null;
        self.shell_output_length = rendered.len;
        return self.shell_output[0..self.shell_output_length];
    }

    fn append(self: *World, path: []const u8, content: []const u8) bool {
        if (self.refuse_writes) return false;
        if (!self.exists(path)) return self.write(path, content);
        if (self.file_content_length + content.len > self.file_content.len) return false;
        @memcpy(self.file_content[self.file_content_length..][0..content.len], content);
        self.file_content_length += content.len;
        return true;
    }

    fn delete(self: *World, path: []const u8) bool {
        if (!self.exists(path)) return false;
        self.file_name_length = 0;
        self.file_content_length = 0;
        return true;
    }

    fn rename(self: *World, from: []const u8, to: []const u8) bool {
        if (!self.exists(from)) return false;
        if (to.len == 0 or to.len > self.file_name.len) return false;
        @memcpy(self.file_name[0..to.len], to);
        self.file_name_length = to.len;
        return true;
    }

    /// The file's bytes, or null when nothing of that name was written.
    /// Borrowed until the next write.
    fn read(self: *const World, path: []const u8) ?[]const u8 {
        if (!self.exists(path)) return null;
        return self.file_content[0..self.file_content_length];
    }

    fn write(self: *World, path: []const u8, content: []const u8) bool {
        if (self.refuse_writes) return false;
        if (path.len == 0 or path.len > self.file_name.len) return false;
        if (content.len > self.file_content.len) return false;
        self.place(path, content);
        return true;
    }

    fn exists(self: *const World, path: []const u8) bool {
        if (self.file_name_length == 0) return false;
        return std.mem.eql(u8, self.file_name[0..self.file_name_length], path);
    }

    /// What is at `path`, or null for a world that will not say
    /// (`abi.PathKindFn`).
    ///
    /// The order is what a real `stat` would answer: a refusal beats
    /// everything, because a world that will not look has not looked;
    /// then the things this world *did* — a directory it was made to
    /// hold, the one file it holds — because a spec that created
    /// something must see it; and the script last, for the names
    /// nothing in this world created.
    fn kindOf(self: *const World, path: []const u8) ?i64 {
        const wanted = normalizedPath(path);
        for (self.refused_kinds) |refused| {
            const under = normalizedPath(refused);
            if (!std.mem.startsWith(u8, wanted, under)) continue;
            if (wanted.len == under.len or wanted[under.len] == '/') return null;
        }
        if (self.hasDirectory(wanted)) return 2;
        if (self.exists(wanted)) return 1;
        for (self.kinds) |row| {
            if (std.mem.eql(u8, normalizedPath(row.path), wanted)) return @intFromEnum(row.kind);
        }
        return 0;
    }

    /// A path as this world names it: without a trailing separator,
    /// and without the `./` a listing's own `paths.join` puts in front
    /// of every entry.  A world where `./notes` and `notes` are two
    /// different things would be a world no file system is.
    fn normalizedPath(path: []const u8) []const u8 {
        var wanted = trimmedPath(path);
        while (wanted.len > 2 and std.mem.startsWith(u8, wanted, "./")) wanted = wanted[2..];
        return wanted;
    }

    fn argument(self: *const World, index: i64) ?[]const u8 {
        if (index < 0 or index >= self.arguments.len) return null;
        return self.arguments[@intCast(index)];
    }

    fn nextKey(self: *World) ?Key {
        if (self.keys_read >= self.keys.len) {
            self.last_event = .{ .name = "" };
            return null;
        }
        defer self.keys_read += 1;
        self.last_event = self.keys[self.keys_read];
        return self.last_event;
    }

    fn eventData(self: *const World, field: i64) i64 {
        return switch (field) {
            0 => self.last_event.row,
            1 => self.last_event.column,
            2 => self.last_event.button,
            3 => self.last_event.modifiers,
            4 => self.last_event.value,
            else => 0,
        };
    }

    /// The listing a compiled program takes, NUL-joined into this
    /// world's own buffer.  Null when the world will not list.
    fn joinedDirectory(self: *World, path: []const u8) ?[]const u8 {
        const names = self.listing(path) orelse return null;
        self.joined_length = 0;
        for (names) |name| {
            std.debug.assert(self.joined_length + name.len + 1 <= self.joined_storage.len);
            @memcpy(self.joined_storage[self.joined_length..][0..name.len], name);
            self.joined_length += name.len;
            self.joined_storage[self.joined_length] = 0;
            self.joined_length += 1;
        }
        return self.joined_storage[0..self.joined_length];
    }

    /// One directory exists, named "." ; anything else is a listing
    /// the world refuses, which is the `io_failed` side under test.
    fn listing(self: *const World, path: []const u8) ?[]const []const u8 {
        if (!std.mem.eql(u8, path, ".")) return null;
        return self.directory;
    }

    // -- the byte channel (docs/BYTES.md) ------------------------------
    //
    // One open file at a time, which is all a world with one file can
    // have.  The handle number never repeats, so a handle that outlived
    // its close is told from a live one and a close is observable — the
    // world can say "that file is not open any more", which is what a
    // scope-end-closes spec has to be able to see.

    /// How much of a write this world takes at a time.  Deliberately
    /// tiny: a handle write is *defined* to be allowed to fall short
    /// (docs/BYTES.md R4), and a world that never falls short is one
    /// that never proves the caller loops.
    const short_write: usize = 3;

    fn openAt(self: *World, path: []const u8, mode: i64, handle: *i64) abi.Answer {
        const wanted: runtime.files.Mode = @enumFromInt(mode);
        switch (wanted) {
            .read => if (!self.exists(path)) return .no,
            .write => if (!self.write(path, "")) return .no,
            .append => if (!self.exists(path)) {
                if (!self.write(path, "")) return .no;
            } else if (self.refuse_writes) return .no,
            else => return .no,
        }
        if (self.open_handle != null) return .no;
        self.next_handle += 1;
        self.open_handle = self.next_handle;
        self.handle_position = 0;
        self.handle_writes = wanted != .read;
        handle.* = self.next_handle;
        return .yes;
    }

    fn readFrom(self: *World, handle: i64, into: []u8, filled: *i64) abi.Answer {
        if (self.open_handle != handle) return .no;
        if (self.handle_writes) return .no;
        const rest = self.file_content[self.handle_position..self.file_content_length];
        const taken = @min(rest.len, into.len);
        @memcpy(into[0..taken], rest[0..taken]);
        self.handle_position += taken;
        filled.* = @intCast(taken);
        return .yes;
    }

    fn writeTo(self: *World, handle: i64, from: []const u8, written: *i64) abi.Answer {
        if (self.open_handle != handle) return .no;
        if (!self.handle_writes or self.refuse_writes) return .no;
        const wanted = @min(from.len, short_write);
        if (self.file_content_length + wanted > self.file_content.len) return .no;
        @memcpy(self.file_content[self.file_content_length..][0..wanted], from[0..wanted]);
        self.file_content_length += wanted;
        written.* = @intCast(wanted);
        return .yes;
    }

    fn flushAt(self: *World, handle: i64) abi.Answer {
        return if (self.open_handle == handle) .yes else .no;
    }

    fn closeAt(self: *World, handle: i64) abi.Answer {
        if (self.open_handle != handle) return .no;
        self.open_handle = null;
        return .yes;
    }
};

/// The five C functions a host installs for the byte channel, over any
/// context that keeps a `world`.
///
/// **One generator rather than two hand-written sets.**  Every other
/// row of these two hosts is written twice because the two engines
/// reach a host differently — but this channel is not reached by either
/// engine: `libluce_rt` holds it and calls it, so both arms install
/// literally the same behaviour, and a generator is how "the same" is
/// said once instead of asserted in a comment.  The two return types
/// are the one difference: `abi.Host`'s slots answer `abi.Answer` and
/// `runtime.files.Channel`'s answer the plain `i32` the runtime library
/// speaks, which are the same three numbers.
/// The thread channel both spec hosts offer, written once
/// (docs/THREADS.md D8).
///
/// The same shape as `HandleChannel` and for the same reason: a host's
/// whole contribution to concurrency is a thread, so the two arms hand
/// over the same two functions and differ only in whether the answer is
/// an `abi.Answer` or the plain `i32` the runtime library speaks.
///
/// **Threads under a leak-checked test allocator are real threads.**  A
/// spec's workers run on `std.Thread` exactly as loom's do, which is
/// the point of D10: if the oracle faked them the two-engine comparison
/// would be comparing one engine's concurrency with the other's
/// pretence.
fn ThreadChannel(comptime Owner: type) type {
    return struct {
        const Body = *const fn (argument: ?*anyopaque) callconv(.c) void;
        const no_handle: i64 = 0;

        fn ownerOf(context: ?*anyopaque) *Owner {
            return @ptrCast(@alignCast(context.?));
        }

        fn go(body: Body, argument: ?*anyopaque) void {
            body(argument);
        }

        fn start(owner: *Owner, body: Body, argument: ?*anyopaque) ?i64 {
            const started = std.Thread.spawn(.{}, go, .{ body, argument }) catch return null;

            // Start outside the registry lock: the new thread may
            // immediately spawn a nested worker and enter this table.
            owner.thread_mutex.lockUncancelable(testing.io);
            if (owner.threads_closing) {
                owner.thread_mutex.unlock(testing.io);
                started.join();
                return null;
            }
            for (&owner.threads, 0..) |*row, index| {
                if (row.* != null) continue;

                // Rows are reusable storage, never identity.  A stale
                // task value must not acquire a later occupant of the
                // same row, so handles only move forward for the life
                // of this registry.
                const handle = owner.next_thread_handle;
                if (handle == std.math.maxInt(i64)) break;
                owner.next_thread_handle = handle + 1;
                row.* = started;
                owner.thread_handles[index] = handle;
                owner.thread_mutex.unlock(testing.io);
                return handle;
            }
            owner.thread_mutex.unlock(testing.io);
            // No room left in the fixed table: the thread must not be
            // left running with nobody able to wait for it.  Join
            // outside the lock so it can enter this registry itself.
            started.join();
            return null;
        }

        fn waitFor(owner: *Owner, thread: i64) bool {
            owner.thread_mutex.lockUncancelable(testing.io);
            if (thread < 1) {
                owner.thread_mutex.unlock(testing.io);
                return false;
            }

            for (&owner.thread_handles, 0..) |*handle, index| {
                if (handle.* != thread) continue;

                // Detach the thread atomically.  Keep its identity
                // until this row is reused so a repeated join remains
                // harmless, as it is in the dynamic host; a new
                // occupant overwrites it with a monotonic handle.
                const running = owner.threads[index];
                owner.threads[index] = null;
                owner.thread_mutex.unlock(testing.io);

                if (running) |detached| detached.join();
                return true;
            }

            owner.thread_mutex.unlock(testing.io);
            return false;
        }

        fn close(owner: *Owner) void {
            while (true) {
                owner.thread_mutex.lockUncancelable(testing.io);
                owner.threads_closing = true;

                var running: ?std.Thread = null;
                for (&owner.threads, 0..) |*row, index| {
                    if (row.*) |detached| {
                        row.* = null;
                        owner.thread_handles[index] = no_handle;
                        running = detached;
                        break;
                    }
                }
                if (running == null) {
                    // Joined rows deliberately retain their identities
                    // until reuse.  Teardown ends that lifetime and
                    // invalidates every handle from this registry.
                    @memset(&owner.thread_handles, no_handle);
                }
                owner.thread_mutex.unlock(testing.io);

                // Detach one under the lock and join it outside.  It
                // may have published a nested worker before observing
                // that this registry is closing, so inspect the table
                // again after every join.
                if (running) |detached| {
                    detached.join();
                } else {
                    return;
                }
            }
        }

        fn spawn(
            context: ?*anyopaque,
            body: Body,
            argument: ?*anyopaque,
            thread: *i64,
        ) callconv(.c) abi.Answer {
            thread.* = start(ownerOf(context), body, argument) orelse return .no;
            return .yes;
        }

        fn join(context: ?*anyopaque, thread: i64) callconv(.c) abi.Answer {
            return if (waitFor(ownerOf(context), thread)) .yes else .no;
        }

        fn channel(owner: *Owner) luce.runtime.workers.Channel {
            const Plain = struct {
                fn spawnPlain(
                    context: ?*anyopaque,
                    body: Body,
                    argument: ?*anyopaque,
                    thread: *i64,
                ) callconv(.c) i32 {
                    return @intFromEnum(spawn(context, body, argument, thread));
                }
                fn joinPlain(context: ?*anyopaque, thread: i64) callconv(.c) i32 {
                    return @intFromEnum(join(context, thread));
                }
            };
            return .{ .context = owner, .spawn = Plain.spawnPlain, .join = Plain.joinPlain };
        }
    };
}

fn HandleChannel(comptime Owner: type) type {
    return struct {
        fn worldOf(context: ?*anyopaque) *World {
            const owner: *Owner = @ptrCast(@alignCast(context.?));
            return &owner.world;
        }

        fn open(
            context: ?*anyopaque,
            path: [*]const u8,
            path_length: i64,
            mode: i64,
            handle: *i64,
        ) callconv(.c) abi.Answer {
            return worldOf(context).openAt(path[0..@intCast(path_length)], mode, handle);
        }

        fn read(
            context: ?*anyopaque,
            handle: i64,
            into: [*]u8,
            capacity: i64,
            filled: *i64,
        ) callconv(.c) abi.Answer {
            return worldOf(context).readFrom(handle, into[0..@intCast(capacity)], filled);
        }

        fn write(
            context: ?*anyopaque,
            handle: i64,
            from: [*]const u8,
            length: i64,
            written: *i64,
        ) callconv(.c) abi.Answer {
            return worldOf(context).writeTo(handle, from[0..@intCast(length)], written);
        }

        fn flush(context: ?*anyopaque, handle: i64) callconv(.c) abi.Answer {
            return worldOf(context).flushAt(handle);
        }

        fn close(context: ?*anyopaque, handle: i64) callconv(.c) abi.Answer {
            return worldOf(context).closeAt(handle);
        }

        // The `i32` twins the runtime library's own channel takes.

        fn openPlain(
            context: ?*anyopaque,
            path: [*]const u8,
            path_length: i64,
            mode: i64,
            handle: *i64,
        ) callconv(.c) i32 {
            return @intFromEnum(open(context, path, path_length, mode, handle));
        }

        fn readPlain(
            context: ?*anyopaque,
            handle: i64,
            into: [*]u8,
            capacity: i64,
            filled: *i64,
        ) callconv(.c) i32 {
            return @intFromEnum(read(context, handle, into, capacity, filled));
        }

        fn writePlain(
            context: ?*anyopaque,
            handle: i64,
            from: [*]const u8,
            length: i64,
            written: *i64,
        ) callconv(.c) i32 {
            return @intFromEnum(write(context, handle, from, length, written));
        }

        fn flushPlain(context: ?*anyopaque, handle: i64) callconv(.c) i32 {
            return @intFromEnum(flush(context, handle));
        }

        fn closePlain(context: ?*anyopaque, handle: i64) callconv(.c) i32 {
            return @intFromEnum(close(context, handle));
        }

        /// The channel the interpreter installs into `libluce_rt`.
        fn channel(owner: *Owner) runtime.files.Channel {
            return .{
                .context = owner,
                .open = openPlain,
                .read = readPlain,
                .write = writePlain,
                .flush = flushPlain,
                .close = closePlain,
            };
        }
    };
}

/// The screen effects, as words: both hosts record the same ones, so a
/// comparison covers drawing as well as printing.
fn positionText(buffer: []u8, row: i64, col: i64) []const u8 {
    return std.fmt.bufPrint(buffer, "{d},{d}", .{ row, col }) catch unreachable;
}

fn styleText(buffer: []u8, foreground: i64, background: i64, bold: bool) []const u8 {
    return std.fmt.bufPrint(buffer, "{d},{d},{}", .{ foreground, background, bold }) catch unreachable;
}

/// What a host offers: which groups of services exist, how deep it
/// lets calls go, and the world behind them.  Every service in the ABI
/// is optional, and a program that reaches for one that is not there
/// traps `host_unavailable` rather than touching anything — so a spec
/// can withhold a group and demand exactly that.
pub const Provided = struct {
    print: bool = true,
    files: bool = true,
    arguments: bool = true,
    terminal: bool = true,
    /// Standard input, standard error, the clock, and the environment
    /// — four groups because a host may plausibly have any of them
    /// without the others, and each has to fail closed on its own.
    input: bool = true,
    diagnostics: bool = true,
    clock: bool = true,
    environment: bool = true,
    /// The `exited` slot, its own group like every other effect: a
    /// host may run programs whose exits it cannot carry, and `exit`
    /// then fails closed (`host_unavailable`).
    exit: bool = true,
    /// The three machine-fact slots, one group: a host either knows
    /// how to ask its platform about itself or does not, and a program
    /// that reaches one of them without it fails closed like every
    /// other withheld effect.  Distinct from `World.unmeasurable`,
    /// which is a host that *has* the slots and cannot tell — the two
    /// refusals arrive at the same trap by different roads, and both
    /// are worth a spec.
    machine: bool = true,
    /// Whether this host can launch the shell behind `std.os.shell.run`.
    shell: bool = true,
    /// Whether this host can thread (docs/THREADS.md D8).  A host that
    /// cannot is the fail-closed row: a `spawn` traps
    /// `host_unavailable` at the keyword, on both engines, having
    /// touched nothing.
    threads: bool = true,
    /// The depth limit both engines run under.  The ABI's default is
    /// the interpreter's default, so a spec only names this when it
    /// wants a shallower one.
    call_depth: u32 = @intCast(abi.default_call_depth),
    /// Test-only ABI probe: make the compiled print callback return an
    /// integer outside `abi.Answer` so the lowering's fail-closed check can
    /// be exercised without giving the interpreter a malformed vtable.
    malformed_answer: bool = false,
    /// Test-only ABI probe for the bounded `path_kind` payload.
    malformed_path_kind: bool = false,
    /// The world each arm gets its own copy of.
    world: World = .{},

    /// A host that offers nothing at all: every effect fails closed,
    /// which is what a program given no host must see.
    pub const nothing: Provided = .{
        .print = false,
        .files = false,
        .arguments = false,
        .terminal = false,
        .input = false,
        .diagnostics = false,
        .clock = false,
        .environment = false,
        .exit = false,
        .machine = false,
        .shell = false,
        .threads = false,
    };

    /// A host with a console and nothing else: every other service is
    /// optional, and reaching one that is not there must touch nothing
    /// (docs/V2.md's fail-closed rule).
    pub const console_only: Provided = console: {
        var only = nothing;
        only.print = true;
        break :console only;
    };
};

/// One line of a call trace, in the one shape the two engines are
/// compared in.  Written once and used by both hosts, so a difference
/// is a difference in the trace and never in the rendering.
fn traceLine(
    buffer: []u8,
    function: []const u8,
    source: []const u8,
    line: u32,
    column: u32,
) []const u8 {
    return std.fmt.bufPrint(buffer, "{s} {s}:{d}:{d}\n", .{
        function, source, line, column,
    }) catch unreachable;
}

fn droppedLine(buffer: []u8, dropped: u32) []const u8 {
    return std.fmt.bufPrint(buffer, "... {d} more\n", .{dropped}) catch unreachable;
}

/// Put a host message into one of `Capture`'s fixed buffers, and
/// answer how much of the buffer it filled.
///
/// **One policy for both failure channels.**  A message that does not
/// fit is replaced — not truncated — by a sentence naming this
/// harness's own limit.  The oracle arm allocates and always holds the
/// whole message, so a silent prefix would be compared against the
/// whole one and `settle` would print a diff that reads as the two
/// engines disagreeing about the program; a panic, which is what the
/// trap channel used to do, takes the suite down over a message that
/// was only long.  `raiseIo` builds `verb ++ path` (`runtime/heap.zig`),
/// so a long enough path reaches this for real.
///
/// The sentence itself always fits: `buffer` is 256 bytes and the
/// longest form of it is under 80.
fn keepText(buffer: []u8, words: []const u8) usize {
    if (words.len <= buffer.len) {
        @memcpy(buffer[0..words.len], words);
        return words.len;
    }
    const said = std.fmt.bufPrint(
        buffer,
        "<agree.zig: a {d}-byte message does not fit its {d}-byte capture buffer>",
        .{ words.len, buffer.len },
    ) catch unreachable;
    return said.len;
}

// ---------------------------------------------------------------------------
// A host, in Zig
// ---------------------------------------------------------------------------

/// What a run of a compiled program did: the transcript it produced,
/// how it ended, and what it left unfreed.
pub const Capture = struct {
    /// Every worker thread this run started (docs/THREADS.md D8).  A
    /// fixed table because a `Capture` is fixed buffers throughout and
    /// a spec that needs more workers than this is a spec about
    /// something other than the language.  Rows are reusable storage;
    /// their monotonic handles are separate so a stale value can never
    /// name a later worker.
    threads: [max_worker_threads]?std.Thread = @splat(null),
    thread_handles: [max_worker_threads]i64 = @splat(0),
    next_thread_handle: i64 = 1,
    /// D9 serializes effects, not the registry underneath worker
    /// lifetime.  Sibling and nested workers can enter this table at
    /// the same time, so it owns a lock of its own.
    thread_mutex: std.Io.Mutex = .init,
    /// Teardown refuses publication after it starts and joins such a
    /// newly started thread on the spawning side instead.
    threads_closing: bool = false,
    // A Capture needs no separate teardown hook.  The compiled entry
    // calls `luce_rt_close` before it returns; `Runtime.deinit` sweeps
    // every live task, and releasing a task joins its thread.  Thus
    // every row is empty before `agree.zig` can destroy this value.
    world: World = .{},
    printed_storage: [32768]u8 = undefined,
    printed_length: usize = 0,
    trap_code: ?mir.TrapCode = null,
    trap_storage: [256]u8 = undefined,
    trap_length: usize = 0,
    /// The error nobody caught, and the one position it carries — the
    /// other way a run can end (docs/FAILURE.md).
    error_code: ?mir.ErrorCode = null,
    error_storage: [256]u8 = undefined,
    error_length: usize = 0,
    origin_storage: [256]u8 = undefined,
    origin_length: usize = 0,
    /// The call trace that came with the trap, already rendered — the
    /// host has nowhere to allocate, and the text is what is compared.
    trace_storage: [8192]u8 = undefined,
    trace_length: usize = 0,
    /// Objects the run did not free, or null when it exhausted before a
    /// runtime existed.  The callback now publishes the census for
    /// every other ending, including a trap or uncaught error.
    leaked: ?i64 = null,
    /// The status `exit(status)` carried, or null when the program
    /// never exited.
    exit_status: ?i64 = null,
    /// What this host answers when asked how deep calls may go.
    call_depth: i64 = abi.default_call_depth,
    malformed_answer: bool = false,
    malformed_path_kind: bool = false,

    // What this run said, each borrowed from a fixed buffer inside
    // this Capture.  **The next run overwrites all five**: a Capture is
    // reused across the two engines on purpose (the header says why the
    // buffers are fixed), so anything a caller needs after the second
    // run has to be copied out before it starts.

    pub fn printed(self: *const Capture) []const u8 {
        return self.printed_storage[0..self.printed_length];
    }

    pub fn trapMessage(self: *const Capture) []const u8 {
        return self.trap_storage[0..self.trap_length];
    }

    pub fn trapTrace(self: *const Capture) []const u8 {
        return self.trace_storage[0..self.trace_length];
    }

    pub fn errorMessage(self: *const Capture) []const u8 {
        return self.error_storage[0..self.error_length];
    }

    pub fn errorOrigin(self: *const Capture) []const u8 {
        return self.origin_storage[0..self.origin_length];
    }

    /// The table the compiled program indexes.  A withheld group leaves
    /// its slots null, which is what the fail-closed rule reads.
    ///
    /// The one thing `agree.zig` asks a `Capture` for: it looks the
    /// entry symbol up in the loaded library and calls it with this.
    pub fn table(self: *Capture, provided: Provided) abi.Host {
        self.call_depth = provided.call_depth;
        self.malformed_answer = provided.malformed_answer;
        self.malformed_path_kind = provided.malformed_path_kind;
        self.world = provided.world;
        return .{
            .context = self,
            .call_depth = callDepth,
            .print = if (provided.print) print else null,
            .trap = reportTrap,
            .finished = finished,
            .file_read = if (provided.files) fileRead else null,
            .file_write = if (provided.files) fileWrite else null,
            // Retired at ABI 17 (docs/FILESYSTEM.md D16); `path_kind`
            // below is what asks the question now.
            .file_exists = null,
            .arg_count = if (provided.arguments) argCount else null,
            .arg = if (provided.arguments) argAt else null,
            .term_rows = if (provided.terminal) termRows else null,
            .term_cols = if (provided.terminal) termCols else null,
            .term_clear = if (provided.terminal) termClear else null,
            .term_move = if (provided.terminal) termMove else null,
            .term_style = if (provided.terminal) termStyle else null,
            .term_write = if (provided.terminal) termWrite else null,
            .term_flush = if (provided.terminal) termFlush else null,
            .term_event_data = if (provided.terminal) termEventData else null,
            .key_read = if (provided.terminal) keyRead else null,
            .raised = raised,
            .file_append = if (provided.files) fileAppend else null,
            .file_delete = if (provided.files) fileDelete else null,
            .file_rename = if (provided.files) fileRename else null,
            .dir_list = if (provided.files) dirList else null,
            .dir_create = if (provided.files) dirCreate else null,
            .read_line = if (provided.input) readLine else null,
            .print_error = if (provided.diagnostics) printError else null,
            .clock_ms = if (provided.clock) clockMilliseconds else null,
            .epoch_ms = if (provided.clock) epochMilliseconds else null,
            .sleep_ms = if (provided.clock) sleepMilliseconds else null,
            .exited = if (provided.exit) exited else null,
            .env = if (provided.environment) environmentValue else null,
            .os_total_memory = if (provided.machine) totalMemory else null,
            .os_available_memory = if (provided.machine) availableMemory else null,
            .os_cpu_count = if (provided.machine) cpuCount else null,
            .shell_run = if (provided.shell) shellRun else null,
            .handle_open = if (provided.files) Handles.open else null,
            .handle_read = if (provided.files) Handles.read else null,
            .handle_write = if (provided.files) Handles.write else null,
            .handle_flush = if (provided.files) Handles.flush else null,
            .handle_close = if (provided.files) Handles.close else null,
            .worker_spawn = if (provided.threads) Threads.spawn else null,
            .worker_join = if (provided.threads) Threads.join else null,
            .path_kind = if (provided.files) pathKind else null,
        };
    }

    const Handles = HandleChannel(Capture);
    const Threads = ThreadChannel(Capture);

    fn of(context: ?*anyopaque) *Capture {
        return @ptrCast(@alignCast(context.?));
    }

    /// One transcript line: a tag naming the effect, then its text.
    fn record(self: *Capture, tag: []const u8, text: []const u8) void {
        const total = tag.len + text.len + 1;
        if (self.printed_length + total > self.printed_storage.len) @panic("printed too much");
        @memcpy(self.printed_storage[self.printed_length..][0..tag.len], tag);
        self.printed_length += tag.len;
        @memcpy(self.printed_storage[self.printed_length..][0..text.len], text);
        self.printed_length += text.len;
        self.printed_storage[self.printed_length] = '\n';
        self.printed_length += 1;
    }

    fn print(context: ?*anyopaque, text: [*]const u8, length: i64) callconv(.c) abi.Answer {
        const self = of(context);
        self.record("", text[0..@intCast(length)]);
        return if (self.malformed_answer) @enumFromInt(2) else .yes;
    }

    fn raised(
        context: ?*anyopaque,
        code: i32,
        message: [*]const u8,
        message_length: i64,
        origin: *const abi.TraceFrame,
    ) callconv(.c) void {
        const self = of(context);
        const words = message[0..@intCast(message_length)];
        self.error_code = @enumFromInt(code);
        self.error_length = keepText(&self.error_storage, words);
        const rendered = traceLine(
            &self.origin_storage,
            origin.function[0..@intCast(origin.function_length)],
            origin.source[0..@intCast(origin.source_length)],
            origin.line,
            origin.column,
        );
        self.origin_length = rendered.len;
    }

    fn callDepth(context: ?*anyopaque) callconv(.c) i64 {
        return of(context).call_depth;
    }

    fn reportTrap(
        context: ?*anyopaque,
        code: i32,
        message: [*]const u8,
        message_length: i64,
        frames: [*]const abi.TraceFrame,
        frame_count: i64,
        dropped: i64,
    ) callconv(.c) void {
        const self = of(context);
        const words = message[0..@intCast(message_length)];
        self.trap_code = @enumFromInt(code);
        self.trap_length = keepText(&self.trap_storage, words);

        var encoded: [512]u8 = undefined;
        self.trace_length = 0;
        for (frames[0..@intCast(frame_count)]) |frame| {
            self.keepTrace(traceLine(
                &encoded,
                frame.function[0..@intCast(frame.function_length)],
                frame.source[0..@intCast(frame.source_length)],
                frame.line,
                frame.column,
            ));
        }
        if (dropped != 0) self.keepTrace(droppedLine(&encoded, @intCast(dropped)));
    }

    fn keepTrace(self: *Capture, line: []const u8) void {
        if (self.trace_length + line.len > self.trace_storage.len) @panic("trace too long");
        @memcpy(self.trace_storage[self.trace_length..][0..line.len], line);
        self.trace_length += line.len;
    }

    fn finished(context: ?*anyopaque, leaked: i64) callconv(.c) void {
        of(context).leaked = leaked;
    }

    fn exited(context: ?*anyopaque, status: i64) callconv(.c) void {
        of(context).exit_status = status;
    }

    fn fileRead(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        const found = of(context).world.read(path[0..@intCast(path_length)]) orelse return .no;
        text.* = found.ptr;
        length.* = @intCast(found.len);
        return .yes;
    }

    fn fileWrite(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        content: [*]const u8,
        content_length: i64,
    ) callconv(.c) abi.Answer {
        const wrote = of(context).world.write(
            path[0..@intCast(path_length)],
            content[0..@intCast(content_length)],
        );
        return if (wrote) .yes else .no;
    }

    fn pathKind(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        kind: *i64,
    ) callconv(.c) abi.Answer {
        const self = of(context);
        const found = self.world.kindOf(path[0..@intCast(path_length)]) orelse return .no;
        kind.* = if (self.malformed_path_kind) 99 else found;
        return .yes;
    }

    fn argCount(context: ?*anyopaque) callconv(.c) i64 {
        return @intCast(of(context).world.arguments.len);
    }

    fn argAt(
        context: ?*anyopaque,
        index: i64,
        text: *[*c]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        const found = of(context).world.argument(index) orelse return .no;
        text.* = found.ptr;
        length.* = @intCast(found.len);
        return .yes;
    }

    fn termRows(context: ?*anyopaque) callconv(.c) i64 {
        _ = context;
        return World.rows;
    }

    fn termCols(context: ?*anyopaque) callconv(.c) i64 {
        _ = context;
        return World.cols;
    }

    fn termClear(context: ?*anyopaque) callconv(.c) abi.Answer {
        of(context).record("[clear]", "");
        return .yes;
    }

    fn termMove(context: ?*anyopaque, row: i64, col: i64) callconv(.c) abi.Answer {
        var encoded: [48]u8 = undefined;
        of(context).record("[move]", positionText(&encoded, row, col));
        return .yes;
    }

    fn termStyle(
        context: ?*anyopaque,
        foreground: i64,
        background: i64,
        bold: i32,
    ) callconv(.c) abi.Answer {
        var encoded: [64]u8 = undefined;
        of(context).record("[style]", styleText(&encoded, foreground, background, bold != 0));
        return .yes;
    }

    fn termWrite(context: ?*anyopaque, text: [*]const u8, length: i64) callconv(.c) abi.Answer {
        of(context).record("[write]", text[0..@intCast(length)]);
        return .yes;
    }

    fn termFlush(context: ?*anyopaque) callconv(.c) abi.Answer {
        of(context).record("[flush]", "");
        return .yes;
    }

    fn termEventData(context: ?*anyopaque, field: i64) callconv(.c) i64 {
        return of(context).world.eventData(field);
    }

    fn keyRead(
        context: ?*anyopaque,
        name: *[*]const u8,
        name_length: *i64,
        text: *[*]const u8,
        text_length: *i64,
    ) callconv(.c) abi.Answer {
        const pressed = of(context).world.nextKey() orelse return .no;
        name.* = pressed.name.ptr;
        name_length.* = @intCast(pressed.name.len);
        text.* = pressed.text.ptr;
        text_length.* = @intCast(pressed.text.len);
        return .yes;
    }

    fn fileAppend(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        content: [*]const u8,
        content_length: i64,
    ) callconv(.c) abi.Answer {
        const added = of(context).world.append(
            path[0..@intCast(path_length)],
            content[0..@intCast(content_length)],
        );
        return if (added) .yes else .no;
    }

    fn fileDelete(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
    ) callconv(.c) abi.Answer {
        return if (of(context).world.delete(path[0..@intCast(path_length)])) .yes else .no;
    }

    fn fileRename(
        context: ?*anyopaque,
        from: [*]const u8,
        from_length: i64,
        to: [*]const u8,
        to_length: i64,
    ) callconv(.c) abi.Answer {
        const moved = of(context).world.rename(
            from[0..@intCast(from_length)],
            to[0..@intCast(to_length)],
        );
        return if (moved) .yes else .no;
    }

    fn dirCreate(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
    ) callconv(.c) abi.Answer {
        const made = of(context).world.createDirectory(path[0..@intCast(path_length)]);
        return if (made) .yes else .no;
    }

    fn dirList(
        context: ?*anyopaque,
        path: [*]const u8,
        path_length: i64,
        names: *[*]const u8,
        names_length: *i64,
    ) callconv(.c) abi.Answer {
        const self = of(context);
        const joined = self.world.joinedDirectory(path[0..@intCast(path_length)]) orelse return .no;
        names.* = joined.ptr;
        names_length.* = @intCast(joined.len);
        return .yes;
    }

    fn readLine(
        context: ?*anyopaque,
        prompt: [*]const u8,
        prompt_length: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        const self = of(context);
        self.record("[prompt]", prompt[0..@intCast(prompt_length)]);
        const line = self.world.nextLine() orelse return .no;
        text.* = line.ptr;
        length.* = @intCast(line.len);
        return .yes;
    }

    fn printError(context: ?*anyopaque, text: [*]const u8, length: i64) callconv(.c) abi.Answer {
        of(context).record("[stderr]", text[0..@intCast(length)]);
        return .yes;
    }

    fn clockMilliseconds(context: ?*anyopaque) callconv(.c) i64 {
        return of(context).world.tick();
    }

    fn epochMilliseconds(context: ?*anyopaque, answer: *i64) callconv(.c) abi.Answer {
        return told(of(context).world.epochTick(), answer);
    }

    fn totalMemory(context: ?*anyopaque, answer: *i64) callconv(.c) abi.Answer {
        return told(of(context).world.totalMemory(), answer);
    }

    fn availableMemory(context: ?*anyopaque, answer: *i64) callconv(.c) abi.Answer {
        return told(of(context).world.availableMemory(), answer);
    }

    fn cpuCount(context: ?*anyopaque, answer: *i64) callconv(.c) abi.Answer {
        return told(of(context).world.cpuCount(), answer);
    }

    fn shellRun(
        context: ?*anyopaque,
        command: [*]const u8,
        command_length: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        const output = of(context).world.shellRun(command[0..@intCast(command_length)]) orelse return .no;
        text.* = output.ptr;
        length.* = @intCast(output.len);
        return .yes;
    }

    fn told(fact: ?i64, answer: *i64) abi.Answer {
        answer.* = fact orelse return .no;
        return .yes;
    }

    fn sleepMilliseconds(context: ?*anyopaque, milliseconds: i64) callconv(.c) abi.Answer {
        var encoded: [32]u8 = undefined;
        of(context).record("[sleep]", std.fmt.bufPrint(
            &encoded,
            "{d}",
            .{milliseconds},
        ) catch unreachable);
        return .yes;
    }

    fn environmentValue(
        context: ?*anyopaque,
        name: [*]const u8,
        name_length: i64,
        text: *[*]const u8,
        length: *i64,
    ) callconv(.c) abi.Answer {
        _ = context;
        const found = World.variable(name[0..@intCast(name_length)]) orelse return .no;
        text.* = found.ptr;
        length.* = @intCast(found.len);
        return .yes;
    }
};

/// The same program on the interpreter: the oracle, and the thing a
/// compiled run has to agree with byte for byte.
pub const Reference = struct {
    /// Every worker thread this run started (docs/THREADS.md D8).  A
    /// fixed table because a `Capture` is fixed buffers throughout and
    /// a spec that needs more workers than this is a spec about
    /// something other than the language.  Rows are reusable storage;
    /// their monotonic handles are separate so a stale value can never
    /// name a later worker.
    threads: [max_worker_threads]?std.Thread = @splat(null),
    thread_handles: [max_worker_threads]i64 = @splat(0),
    next_thread_handle: i64 = 1,
    /// The oracle's registry follows the same synchronization and
    /// closing rule as the compiled host's.
    thread_mutex: std.Io.Mutex = .init,
    threads_closing: bool = false,
    /// Worker-enabled oracle runs share this allocator across their
    /// runtimes.  The default testing allocator is thread-safe; a spec
    /// that substitutes another allocator must preserve that contract.
    gpa: Allocator = testing.allocator,
    provided: Provided = .{},
    world: World = .{},
    printed: std.ArrayList(u8) = .empty,
    trap_code: ?mir.TrapCode = null,
    trap_message: []const u8 = "",
    /// The trap's call trace, rendered the same way the compiled host
    /// renders its own.
    trap_trace: std.ArrayList(u8) = .empty,
    /// The error nobody caught, and the one line it carries.
    error_code: ?mir.ErrorCode = null,
    error_message: []const u8 = "",
    error_origin: std.ArrayList(u8) = .empty,
    leaked: ?u32 = null,
    /// The status `exit(status)` carried, or null when the program
    /// never exited.
    exit_status: ?i64 = null,

    pub fn deinit(self: *Reference) void {
        // Keep every field a worker might still reach alive until the
        // registry has refused new publications and drained its rows.
        Threads.close(self);
        self.printed.deinit(self.gpa);
        self.trap_trace.deinit(self.gpa);
        self.error_origin.deinit(self.gpa);
        self.gpa.free(self.trap_message);
        self.gpa.free(self.error_message);
    }

    fn of(context: *anyopaque) *Reference {
        return @ptrCast(@alignCast(context));
    }

    fn record(self: *Reference, tag: []const u8, text: []const u8) error{OutOfMemory}!void {
        try self.printed.appendSlice(self.gpa, tag);
        try self.printed.appendSlice(self.gpa, text);
        try self.printed.append(self.gpa, '\n');
    }

    fn host(self: *Reference) interpreter.Host {
        return .{
            .context = self,
            .print = if (self.provided.print) take else null,
            .path_kind = if (self.provided.files) pathKind else null,
            .file_delete = if (self.provided.files) deleteFile else null,
            .file_rename = if (self.provided.files) renameFile else null,
            .dir_list = if (self.provided.files) listDirectory else null,
            .dir_create = if (self.provided.files) makeDirectory else null,
            .read_line = if (self.provided.input) readLine else null,
            .print_error = if (self.provided.diagnostics) printError else null,
            .clock_ms = if (self.provided.clock) clockMilliseconds else null,
            .epoch_ms = if (self.provided.clock) epochMilliseconds else null,
            .sleep_ms = if (self.provided.clock) sleepMilliseconds else null,
            .env = if (self.provided.environment) environmentValue else null,
            .exited = if (self.provided.exit) exitedHook else null,
            .os_total_memory = if (self.provided.machine) totalMemory else null,
            .os_available_memory = if (self.provided.machine) availableMemory else null,
            .os_cpu_count = if (self.provided.machine) cpuCount else null,
            .shell_run = if (self.provided.shell) shellRun else null,
            .arg_count = if (self.provided.arguments) argCount else null,
            .arg = if (self.provided.arguments) argAt else null,
            .terminal = if (self.provided.terminal) .{
                .context = self,
                .term_rows = termRows,
                .term_cols = termCols,
                .term_clear = termClear,
                .term_move = termMove,
                .term_style = termStyle,
                .term_write = termWrite,
                .term_flush = termFlush,
                .event_data = eventData,
                .key_read = keyRead,
            } else null,
            .files = if (self.provided.files) Handles.channel(self) else .{},
            .workers = if (self.provided.threads) Threads.channel(self) else .{},
        };
    }

    const Handles = HandleChannel(Reference);
    const Threads = ThreadChannel(Reference);

    fn take(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        try of(context).record("", text);
    }

    fn pathKind(context: *anyopaque, path: []const u8) ?i64 {
        return of(context).world.kindOf(path);
    }

    fn deleteFile(context: *anyopaque, path: []const u8) bool {
        return of(context).world.delete(path);
    }

    fn renameFile(context: *anyopaque, from: []const u8, to: []const u8) bool {
        return of(context).world.rename(from, to);
    }

    fn makeDirectory(context: *anyopaque, path: []const u8) bool {
        return of(context).world.createDirectory(path);
    }

    fn listDirectory(
        context: *anyopaque,
        arena: Allocator,
        path: []const u8,
    ) error{OutOfMemory}!?[]const []const u8 {
        _ = arena;
        return of(context).world.listing(path);
    }

    fn readLine(
        context: *anyopaque,
        arena: Allocator,
        prompt: []const u8,
    ) error{OutOfMemory}!?[]const u8 {
        _ = arena;
        const self = of(context);
        try self.record("[prompt]", prompt);
        return self.world.nextLine();
    }

    fn printError(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        try of(context).record("[stderr]", text);
    }

    fn clockMilliseconds(context: *anyopaque) i64 {
        return of(context).world.tick();
    }

    fn epochMilliseconds(context: *anyopaque) ?i64 {
        return of(context).world.epochTick();
    }

    fn sleepMilliseconds(context: *anyopaque, milliseconds: i64) void {
        var encoded: [32]u8 = undefined;
        of(context).record("[sleep]", std.fmt.bufPrint(
            &encoded,
            "{d}",
            .{milliseconds},
        ) catch unreachable) catch {};
    }

    fn environmentValue(
        context: *anyopaque,
        arena: Allocator,
        name: []const u8,
    ) error{OutOfMemory}!?[]const u8 {
        _ = context;
        _ = arena;
        return World.variable(name);
    }

    fn argCount(context: *anyopaque) u32 {
        return @intCast(of(context).world.arguments.len);
    }

    fn argAt(context: *anyopaque, arena: Allocator, index: u32) error{OutOfMemory}!?[]const u8 {
        const found = of(context).world.argument(index) orelse return null;
        return try arena.dupe(u8, found);
    }

    fn termRows(context: *anyopaque) i64 {
        _ = context;
        return World.rows;
    }

    fn termCols(context: *anyopaque) i64 {
        _ = context;
        return World.cols;
    }

    fn termClear(context: *anyopaque) error{OutOfMemory}!void {
        try of(context).record("[clear]", "");
    }

    fn termMove(context: *anyopaque, row: i64, col: i64) error{OutOfMemory}!void {
        var encoded: [48]u8 = undefined;
        try of(context).record("[move]", positionText(&encoded, row, col));
    }

    fn termStyle(
        context: *anyopaque,
        foreground: i64,
        background: i64,
        bold: bool,
    ) error{OutOfMemory}!void {
        var encoded: [64]u8 = undefined;
        try of(context).record("[style]", styleText(&encoded, foreground, background, bold));
    }

    fn termWrite(context: *anyopaque, text: []const u8) error{OutOfMemory}!void {
        try of(context).record("[write]", text);
    }

    fn termFlush(context: *anyopaque) error{OutOfMemory}!void {
        try of(context).record("[flush]", "");
    }

    fn eventData(context: *anyopaque, field: i64) i64 {
        return of(context).world.eventData(field);
    }

    fn keyRead(context: *anyopaque, arena: Allocator) error{OutOfMemory}!?interpreter.KeyEvent {
        _ = arena;
        const pressed = of(context).world.nextKey() orelse return null;
        return .{ .name = pressed.name, .text = pressed.text };
    }

    fn exitedHook(context: *anyopaque, status: i64) void {
        of(context).exit_status = status;
    }

    fn totalMemory(context: *anyopaque) ?i64 {
        return of(context).world.totalMemory();
    }

    fn availableMemory(context: *anyopaque) ?i64 {
        return of(context).world.availableMemory();
    }

    fn cpuCount(context: *anyopaque) ?i64 {
        return of(context).world.cpuCount();
    }

    fn shellRun(
        context: *anyopaque,
        arena: Allocator,
        command: []const u8,
    ) error{OutOfMemory}!?[]const u8 {
        const output = of(context).world.shellRun(command) orelse return null;
        return try arena.dupe(u8, output);
    }

    pub fn run(self: *Reference, compiled: *const mir.Program) !void {
        self.world = self.provided.world;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const result = try interpreter.run(
            .{ .arena = arena.allocator(), .objects = self.gpa },
            compiled,
            .{ .call_depth = self.provided.call_depth },
            self.host(),
        );
        switch (result) {
            .success => |ended| self.leaked = ended.leaked_objects,
            .exited => |ended| {
                self.exit_status = ended.status;
                self.leaked = ended.leaked_objects;
            },
            .trap => |raised| {
                self.trap_code = raised.code;
                self.leaked = raised.leaked_objects;
                // The arena goes at the end of this function, so keep
                // the words rather than a borrow of them.
                self.trap_message = try self.gpa.dupe(u8, raised.message);
                var encoded: [512]u8 = undefined;
                for (raised.trace) |frame| {
                    try self.trap_trace.appendSlice(self.gpa, traceLine(
                        &encoded,
                        frame.function,
                        frame.source,
                        frame.line,
                        frame.column,
                    ));
                }
                if (raised.dropped != 0) {
                    try self.trap_trace.appendSlice(
                        self.gpa,
                        droppedLine(&encoded, raised.dropped),
                    );
                }
            },
            .errored => |raised| {
                self.error_code = raised.code;
                self.leaked = raised.leaked_objects;
                self.error_message = try self.gpa.dupe(u8, raised.message);
                var encoded: [512]u8 = undefined;
                try self.error_origin.appendSlice(self.gpa, traceLine(
                    &encoded,
                    raised.origin.function,
                    raised.origin.source,
                    raised.origin.line,
                    raised.origin.column,
                ));
            },
        }
    }
};

// ---------------------------------------------------------------------------
// The capture buffers' own test
// ---------------------------------------------------------------------------

test "the spec thread channel synchronizes sibling nested registries" {
    const Owner = struct {
        threads: [max_worker_threads]?std.Thread = @splat(null),
        thread_handles: [max_worker_threads]i64 = @splat(0),
        next_thread_handle: i64 = 1,
        thread_mutex: std.Io.Mutex = .init,
        threads_closing: bool = false,
    };
    const Threads = ThreadChannel(Owner);
    const Stress = struct {
        channel: luce.runtime.workers.Channel,
        go: std.atomic.Value(bool) = .init(false),
        ready: std.atomic.Value(u32) = .init(0),
        completed: std.atomic.Value(u32) = .init(0),
        failures: std.atomic.Value(u32) = .init(0),

        fn pause() void {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }

        fn leaf(argument: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(argument.?));
            _ = self.completed.fetchAdd(1, .monotonic);
        }

        fn branch(argument: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(argument.?));
            _ = self.ready.fetchAdd(1, .release);
            while (!self.go.load(.acquire)) pause();

            var nested: i64 = 0;
            if (self.channel.spawn.?(
                self.channel.context,
                leaf,
                self,
                &nested,
            ) != luce.runtime.workers.yes) {
                _ = self.failures.fetchAdd(1, .monotonic);
                return;
            }
            if (self.channel.join.?(self.channel.context, nested) != luce.runtime.workers.yes) {
                _ = self.failures.fetchAdd(1, .monotonic);
            }
        }
    };

    const sibling_count = max_worker_threads / 2;
    const rounds = 64;
    var owner: Owner = .{};
    var stress: Stress = .{ .channel = Threads.channel(&owner) };
    defer {
        // Also releases already-published branches if an assertion or
        // an OS thread-spawn failure exits a round early.
        stress.go.store(true, .release);
        Threads.close(&owner);
    }
    var siblings: [sibling_count]i64 = undefined;
    for (0..rounds) |_| {
        stress.go.store(false, .release);
        stress.ready.store(0, .release);
        for (&siblings) |*thread| {
            try testing.expectEqual(
                luce.runtime.workers.yes,
                stress.channel.spawn.?(stress.channel.context, Stress.branch, &stress, thread),
            );
        }
        while (stress.ready.load(.acquire) != sibling_count) Stress.pause();
        stress.go.store(true, .release);
        for (siblings) |thread| {
            try testing.expectEqual(
                luce.runtime.workers.yes,
                stress.channel.join.?(stress.channel.context, thread),
            );
        }
    }

    try testing.expectEqual(@as(u32, 0), stress.failures.load(.acquire));
    try testing.expectEqual(@as(u32, sibling_count * rounds), stress.completed.load(.acquire));
    for (owner.threads) |thread| try testing.expect(thread == null);
}

test "the spec thread channel rejects a stale handle after row reuse" {
    const Owner = struct {
        threads: [max_worker_threads]?std.Thread = @splat(null),
        thread_handles: [max_worker_threads]i64 = @splat(0),
        next_thread_handle: i64 = 1,
        thread_mutex: std.Io.Mutex = .init,
        threads_closing: bool = false,
    };
    const Threads = ThreadChannel(Owner);
    const Worker = struct {
        fn run(_: ?*anyopaque) callconv(.c) void {}
    };

    var owner: Owner = .{};
    defer Threads.close(&owner);
    const channel = Threads.channel(&owner);

    var first: i64 = 0;
    try testing.expectEqual(
        luce.runtime.workers.yes,
        channel.spawn.?(channel.context, Worker.run, null, &first),
    );
    try testing.expectEqual(luce.runtime.workers.yes, channel.join.?(channel.context, first));
    try testing.expectEqual(luce.runtime.workers.yes, channel.join.?(channel.context, first));

    var second: i64 = 0;
    try testing.expectEqual(
        luce.runtime.workers.yes,
        channel.spawn.?(channel.context, Worker.run, null, &second),
    );
    try testing.expect(second > first);
    // With only one live worker, the second spawn necessarily reused
    // the first physical row; its independent identity is new.
    try testing.expectEqual(second, owner.thread_handles[0]);
    try testing.expectEqual(luce.runtime.workers.no, channel.join.?(channel.context, first));
    try testing.expectEqual(luce.runtime.workers.yes, channel.join.?(channel.context, second));
    try testing.expectEqual(second, owner.thread_handles[0]);
}

test "the spec thread channel closes publication and joins outside its lock" {
    const Owner = struct {
        threads: [max_worker_threads]?std.Thread = @splat(null),
        thread_handles: [max_worker_threads]i64 = @splat(0),
        next_thread_handle: i64 = 1,
        thread_mutex: std.Io.Mutex = .init,
        threads_closing: bool = false,
    };
    const Threads = ThreadChannel(Owner);
    const Closing = struct {
        channel: luce.runtime.workers.Channel,
        entered: std.atomic.Value(bool) = .init(false),
        go: std.atomic.Value(bool) = .init(false),
        nested_answer: std.atomic.Value(i32) = .init(luce.runtime.workers.exhausted),
        probe_entered: std.atomic.Value(bool) = .init(false),

        fn pause() void {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }

        fn probe(argument: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(argument.?));
            if (self.channel.join.?(self.channel.context, 0) == luce.runtime.workers.no) {
                self.probe_entered.store(true, .release);
            }
        }

        fn parent(argument: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(argument.?));
            self.entered.store(true, .release);
            while (!self.go.load(.acquire)) pause();

            var nested: i64 = 0;
            const answer = self.channel.spawn.?(
                self.channel.context,
                probe,
                self,
                &nested,
            );
            self.nested_answer.store(answer, .release);
            if (answer == luce.runtime.workers.yes) {
                _ = self.channel.join.?(self.channel.context, nested);
            }
        }

        fn close(owner: *Owner) void {
            Threads.close(owner);
        }
    };

    var owner: Owner = .{};
    var closing: Closing = .{ .channel = Threads.channel(&owner) };
    defer {
        // Do not strand the parent if spawning the teardown probe
        // itself fails.
        closing.go.store(true, .release);
        Threads.close(&owner);
    }
    var parent: i64 = 0;
    try testing.expectEqual(
        luce.runtime.workers.yes,
        closing.channel.spawn.?(closing.channel.context, Closing.parent, &closing, &parent),
    );
    while (!closing.entered.load(.acquire)) Closing.pause();

    const teardown = try std.Thread.spawn(.{}, Closing.close, .{&owner});
    while (true) {
        owner.thread_mutex.lockUncancelable(testing.io);
        const started = owner.threads_closing;
        owner.thread_mutex.unlock(testing.io);
        if (started) break;
        Closing.pause();
    }
    closing.go.store(true, .release);
    teardown.join();

    try testing.expectEqual(luce.runtime.workers.no, closing.nested_answer.load(.acquire));
    try testing.expect(closing.probe_entered.load(.acquire));
    for (owner.threads) |thread| try testing.expect(thread == null);
    // Teardown clears both the row and its identity.
    try testing.expectEqual(
        luce.runtime.workers.no,
        closing.channel.join.?(closing.channel.context, parent),
    );
}

test "a message too long for a capture buffer names the harness, not a diff" {
    // The two failure channels used to answer this differently — the
    // error channel kept a silent 256-byte prefix, the trap channel
    // panicked — and the truncating one was reachable: `raiseIo`
    // builds `verb ++ path` and a path can be longer than that.  One
    // policy now, and one that reads as what it is in a failure.
    var buffer: [256]u8 = undefined;

    const short = "cannot read notes.txt";
    try testing.expectEqual(short.len, keepText(&buffer, short));
    try testing.expectEqualStrings(short, buffer[0..short.len]);

    // Exactly full still fits, whole.
    const exact = "x" ** 256;
    try testing.expectEqual(@as(usize, 256), keepText(&buffer, exact));
    try testing.expectEqualStrings(exact, buffer[0..256]);

    // One byte over, and the buffer holds a sentence about the buffer.
    const over = "x" ** 257;
    const length = keepText(&buffer, over);
    try testing.expect(length < buffer.len);
    try testing.expectEqualStrings(
        "<agree.zig: a 257-byte message does not fit its 256-byte capture buffer>",
        buffer[0..length],
    );
}
