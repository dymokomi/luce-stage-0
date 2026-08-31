//! A non-silent runner for the two long release-gate test binaries.
//!
//! Zig's server-mode test protocol gives the build runner exact results, but
//! a non-interactive build may show none of them until the process exits.  The
//! full differential specification can take minutes, so this simple runner
//! emits bounded progress and a heartbeat naming the test currently running.

const builtin = @import("builtin");
const std = @import("std");
const suites = @import("test_suites.zig");
const testing = std.testing;

pub const std_options: std.Options = .{ .logFn = log };

const heartbeat_interval: std.Io.Clock.Duration = .{
    .raw = std.Io.Duration.fromSeconds(15),
    .clock = .awake,
};
const progress_interval = 25;
const runner_io = std.Io.Threaded.global_single_threaded.io();

var log_error_count: usize = 0;
var argument_allocator: std.heap.FixedBufferAllocator = .init(&argument_buffer);
var argument_buffer: [8192]u8 = undefined;

const Heartbeat = struct {
    done: std.Io.Event = .unset,
    current: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),
    completed: std.atomic.Value(usize) = .init(0),
    tests: []const std.builtin.TestFn,
    label: []const u8,
};

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();
    if (builtin.fuzz) @panic("the progress runner is for deterministic test lanes");

    const args = init.args.toSlice(argument_allocator.allocator()) catch
        @panic("unable to read test-runner arguments");
    var label: []const u8 = "tests";
    var range: ?[2]usize = null;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed");
        } else if (std.mem.startsWith(u8, arg, "--suite=")) {
            label = arg["--suite=".len..];
        } else if (std.mem.startsWith(u8, arg, "--range=")) {
            const spoken = arg["--range=".len..];
            const comma = std.mem.indexOfScalar(u8, spoken, ',') orelse
                @panic("unable to parse --range");
            range = .{
                std.fmt.parseUnsigned(usize, spoken[0..comma], 10) catch
                    @panic("unable to parse --range"),
                std.fmt.parseUnsigned(usize, spoken[comma + 1 ..], 10) catch
                    @panic("unable to parse --range"),
            };
        } else {
            std.debug.print("unrecognized test-runner argument: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    const every_test = builtin.test_functions;

    // **A long lane runs as several processes, and this is why.**  Each
    // compiled specification `dlopen`s an artifact, every artifact
    // carries thread-local storage (Zig's own runtime brings some into
    // `libluce_rt`), and macOS charges each such image a loader key
    // that `dlclose` never returns.  A process is good for roughly 500
    // of them; the release gate is past that, and the day it crossed
    // the line the symptom was an abort inside whichever innocent spec
    // ran 476th.  So a run over more tests than one process can host
    // becomes a parent that spawns itself over consecutive slices — the
    // same tests, the same order, the same seed — and each child's exit
    // returns every key and page it held.  A crash takes one shard and
    // names its own tests instead of poisoning the whole run.
    const shard_capacity = 256;
    const specification = std.mem.eql(u8, label, "specifications");
    // Classification is a property of the whole roster, so the parent
    // holds every name to the one-owner rule before any child runs; a
    // child sees only its slice, where an absent suite is expected.
    if (specification and range == null) {
        var invalid = false;
        var whole_totals = [_]usize{0} ** @typeInfo(suites.Suite).@"enum".fields.len;
        for (every_test) |test_fn| {
            if (suites.matchCount(test_fn.name) != 1) {
                std.debug.print("[test:{s}] unclassified or overlapping: {s}\n", .{ label, test_fn.name });
                invalid = true;
                continue;
            }
            whole_totals[@intFromEnum(suites.classify(test_fn.name).?)] += 1;
        }
        for (suites.definitions) |suite| {
            if (whole_totals[@intFromEnum(suite.suite)] != 0) continue;
            std.debug.print("[test:{s}] empty suite: {s}\n", .{ label, suite.label });
            invalid = true;
        }
        if (invalid) std.process.exit(1);
    }
    if (range == null and every_test.len > shard_capacity) {
        runShards(args, label, every_test.len, shard_capacity);
        unreachable;
    }
    const bounds = range orelse [2]usize{ 0, every_test.len };
    if (bounds[1] > every_test.len or bounds[0] > bounds[1]) {
        std.debug.print("[test:{s}] --range {d},{d} is outside the {d} tests\n", .{
            label, bounds[0], bounds[1], every_test.len,
        });
        std.process.exit(1);
    }
    const tests = every_test[bounds[0]..bounds[1]];
    var suite_totals = [_]usize{0} ** @typeInfo(suites.Suite).@"enum".fields.len;
    if (specification) {
        // Tally this process's own slice for the queued/complete
        // accounting; the whole-roster validation already ran above
        // (or in the parent, for a shard).
        for (tests) |test_fn| {
            const suite = suites.classify(test_fn.name) orelse continue;
            suite_totals[@intFromEnum(suite)] += 1;
        }
    }

    std.debug.print("[test:{s}] starting {d} tests (seed 0x{x})\n", .{
        label,
        tests.len,
        testing.random_seed,
    });
    if (specification) {
        for (suites.definitions) |suite| {
            const queued = suite_totals[@intFromEnum(suite.suite)];
            if (queued == 0) continue;
            std.debug.print("[test:{s}] queued {d} tests\n", .{ suite.label, queued });
        }
    }

    var heartbeat: Heartbeat = .{ .tests = tests, .label = label };
    const heartbeat_thread = std.Thread.spawn(.{}, heartbeatMain, .{&heartbeat}) catch null;
    if (heartbeat_thread == null) {
        std.debug.print("[test:{s}] warning: heartbeat thread unavailable\n", .{label});
    }

    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaked: usize = 0;
    var suite_completed = [_]usize{0} ** @typeInfo(suites.Suite).@"enum".fields.len;
    var suite_started = [_]bool{false} ** @typeInfo(suites.Suite).@"enum".fields.len;

    for (tests, 0..) |test_fn, index| {
        heartbeat.current.store(index, .release);
        if (specification) {
            const suite = suites.classify(test_fn.name).?;
            const suite_index = @intFromEnum(suite);
            if (!suite_started[suite_index]) {
                suite_started[suite_index] = true;
                std.debug.print("[test:{s}] starting\n", .{suites.definition(suite).label});
            }
        }

        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        testing.log_level = .warn;
        testing.environ = init.environ;
        const errors_before = log_error_count;

        const Outcome = enum { passed, skipped, failed };
        var outcome: Outcome = .passed;
        if (test_fn.func()) |_| {} else |err| switch (err) {
            error.SkipZigTest => outcome = .skipped,
            else => {
                outcome = .failed;
                std.debug.print("[test:{s}] FAIL {s}: {t}\n", .{ label, test_fn.name, err });
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }

        testing.io_instance.deinit();
        var test_environment_failed = false;
        if (testing.allocator_instance.deinit() == .leak) {
            leaked += 1;
            test_environment_failed = true;
            std.debug.print("[test:{s}] LEAK {s}\n", .{ label, test_fn.name });
        }
        if (log_error_count != errors_before) {
            test_environment_failed = true;
            std.debug.print("[test:{s}] ERROR LOG {s}\n", .{ label, test_fn.name });
        }
        if (test_environment_failed) outcome = .failed;
        switch (outcome) {
            .passed => passed += 1,
            .skipped => skipped += 1,
            .failed => failed += 1,
        }

        if (specification) {
            const suite = suites.classify(test_fn.name).?;
            const suite_index = @intFromEnum(suite);
            suite_completed[suite_index] += 1;
            if (suite_completed[suite_index] == suite_totals[suite_index]) {
                std.debug.print("[test:{s}] complete ({d}/{d})\n", .{
                    suites.definition(suite).label,
                    suite_completed[suite_index],
                    suite_totals[suite_index],
                });
            }
        }

        heartbeat.completed.store(index + 1, .release);
        if ((index + 1) % progress_interval == 0 or index + 1 == tests.len) {
            std.debug.print("[test:{s}] progress {d}/{d}\n", .{ label, index + 1, tests.len });
        }
    }

    heartbeat.current.store(std.math.maxInt(usize), .release);
    if (heartbeat_thread) |thread| {
        heartbeat.done.set(runner_io);
        thread.join();
    }

    std.debug.print(
        "[test:{s}] complete: {d} passed, {d} skipped, {d} failed, {d} leaked\n",
        .{ label, passed, skipped, failed, leaked },
    );
    if (failed != 0 or log_error_count != 0 or leaked != 0) std.process.exit(1);
}

/// Parent mode: the same binary, the same arguments, over consecutive
/// slices.  Children inherit this terminal, so progress and failures
/// stream exactly as an unsharded run's would; the parent owns only
/// the shard banners and the verdict.
fn runShards(args: []const []const u8, label: []const u8, total: usize, capacity: usize) noreturn {
    // Spawning wants real memory (argv duplication, an arena inside the
    // io layer); the fixed argument buffer is for arguments alone, and
    // the global single-threaded io carries no allocator at all.
    const gpa = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const spawn_io = threaded.io();
    const shards = (total + capacity - 1) / capacity;
    std.debug.print("[test:{s}] {d} tests across {d} processes (loader key ceiling)\n", .{
        label, total, shards,
    });
    var start: usize = 0;
    var shard: usize = 0;
    var failed = false;
    while (start < total) : (shard += 1) {
        const end = @min(start + capacity, total);
        var range_word_buffer: [64]u8 = undefined;
        const range_word = std.fmt.bufPrint(&range_word_buffer, "--range={d},{d}", .{ start, end }) catch
            @panic("unable to render --range");
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        argv.appendSlice(gpa, args) catch @panic("out of argument memory");
        argv.append(gpa, range_word) catch @panic("out of argument memory");
        std.debug.print("[test:{s}] shard {d}/{d}: tests {d}..{d}\n", .{
            label, shard + 1, shards, start, end,
        });
        var child = std.process.spawn(spawn_io, .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch @panic("unable to spawn a test shard");
        const term = child.wait(spawn_io) catch @panic("unable to wait for a test shard");
        if (term != .exited or term.exited != 0) {
            failed = true;
            std.debug.print("[test:{s}] shard {d}/{d} failed\n", .{ label, shard + 1, shards });
        }
        start = end;
    }
    if (failed) std.process.exit(1);
    std.debug.print("[test:{s}] all {d} shards passed\n", .{ label, shards });
    std.process.exit(0);
}

fn heartbeatMain(state: *Heartbeat) void {
    while (true) {
        state.done.waitTimeout(runner_io, .{ .duration = heartbeat_interval }) catch |err| switch (err) {
            error.Timeout => {
                const current = state.current.load(.acquire);
                if (current < state.tests.len) {
                    std.debug.print("[test:{s}] heartbeat {d}/{d}; running {s}\n", .{
                        state.label,
                        state.completed.load(.acquire),
                        state.tests.len,
                        state.tests[current].name,
                    });
                }
                continue;
            },
            else => return,
        };
        return;
    }
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_error_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n", args);
    }
}

/// `std.testing.fuzz` delegates here.  The progress runner is used only for
/// deterministic lanes, where a fuzz target means its checked-in corpus plus
/// the empty smoke input; coverage-guided runs retain Zig's server runner.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    if (builtin.fuzz) unreachable;
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var empty: testing.Smith = .{ .in = "" };
    try testOne(context, &empty);
}
