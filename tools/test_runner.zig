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
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed");
        } else if (std.mem.startsWith(u8, arg, "--suite=")) {
            label = arg["--suite=".len..];
        } else {
            std.debug.print("unrecognized test-runner argument: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    const tests = builtin.test_functions;
    const specification = std.mem.eql(u8, label, "specifications");
    var suite_totals = [_]usize{0} ** @typeInfo(suites.Suite).@"enum".fields.len;
    if (specification) {
        var invalid = false;
        for (tests) |test_fn| {
            if (suites.matchCount(test_fn.name) != 1) {
                std.debug.print("[test:{s}] unclassified or overlapping: {s}\n", .{ label, test_fn.name });
                invalid = true;
                continue;
            }
            suite_totals[@intFromEnum(suites.classify(test_fn.name).?)] += 1;
        }
        for (suites.definitions) |suite| {
            if (suite_totals[@intFromEnum(suite.suite)] != 0) continue;
            std.debug.print("[test:{s}] empty suite: {s}\n", .{ label, suite.label });
            invalid = true;
        }
        if (invalid) std.process.exit(1);
    }

    std.debug.print("[test:{s}] starting {d} tests (seed 0x{x})\n", .{
        label,
        tests.len,
        testing.random_seed,
    });
    if (specification) {
        for (suites.definitions) |suite| {
            std.debug.print("[test:{s}] queued {d} tests\n", .{
                suite.label,
                suite_totals[@intFromEnum(suite.suite)],
            });
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
