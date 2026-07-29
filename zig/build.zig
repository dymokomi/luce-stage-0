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

    // The C ABI: libloom.a plus abi/loom.h, and a C smoke test that
    // drives the engine across the border.
    const abi = b.createModule(.{
        .root_source_file = b.path("src/abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const library = b.addLibrary(.{
        .name = "loom",
        .root_module = abi,
        .linkage = .static,
    });
    b.installArtifact(library);

    const smoke = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke.addCSourceFile(.{
        .file = b.path("abi/smoke_test.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    smoke.addIncludePath(b.path("abi"));
    smoke.linkLibrary(library);
    const smoke_test = b.addExecutable(.{ .name = "abi_smoke", .root_module = smoke });
    const run_smoke = b.addRunArtifact(smoke_test);
    test_step.dependOn(&run_smoke.step);
}
