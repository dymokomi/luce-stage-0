const std = @import("std");

// The Loom engine builds as one Zig module, the lucia terminal as its
// first client, and the C ABI as the border for platform shells in
// other languages.  zig build installs both the terminal and libloom.a;
// zig build test runs the engine suite, the terminal suite, and the C
// ABI smoke test.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const loom = b.addModule("loom", .{
        .root_source_file = b.path("loom/loom.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = loom });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the Loom engine tests");
    test_step.dependOn(&run_tests.step);

    // Luce: the small native language for Texel evaluators.
    const luce = b.addModule("luce", .{
        .root_source_file = b.path("luce/luce.zig"),
        .target = target,
        .optimize = optimize,
    });
    const luce_tests = b.addTest(.{ .root_module = luce });
    const run_luce_tests = b.addRunArtifact(luce_tests);
    test_step.dependOn(&run_luce_tests.step);

    // The lucia terminal: a Zig executable speaking the engine module
    // directly.  Loom is the engine; lucia is the executable.
    const app = b.createModule(.{
        .root_source_file = b.path("apps/lucia/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "loom", .module = loom },
            .{ .name = "luce", .module = luce },
        },
    });
    const terminal = b.addExecutable(.{ .name = "lucia", .root_module = app });
    const install_terminal = b.addInstallArtifact(terminal, .{
        .dest_dir = .{ .override = .prefix },
    });
    b.getInstallStep().dependOn(&install_terminal.step);

    const app_tests = b.addTest(.{ .root_module = app });
    const run_app_tests = b.addRunArtifact(app_tests);
    test_step.dependOn(&run_app_tests.step);

    // The C ABI: libloom.a plus abi/loom.h, and a C smoke test that
    // drives the engine across the border.
    const abi = b.createModule(.{
        .root_source_file = b.path("loom/abi.zig"),
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
