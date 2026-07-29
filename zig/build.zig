const std = @import("std");

// The Loom engine builds as one Zig module plus its test suite.  The
// platform shells and legacy C++ tree build separately; only the C ABI
// (abi/loom.h, later) crosses between them.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const loom = b.addModule("loom", .{
        .root_source_file = b.path("src/loom.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = loom });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the Loom engine tests");
    test_step.dependOn(&run_tests.step);
}
