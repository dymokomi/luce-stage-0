const std = @import("std");

// LuciaOS v2 builds two executables from one language module:
//
//   luce  — the compiler (.luc source in, .lc module out)
//   loom  — the terminal that runs compiled Luce programs
//
// zig build installs both plus the compiled bundled programs
// (programs/*.luc -> PREFIX/programs/*.lc); zig build test runs the
// language suite and both app suites.  The editor rides inside the
// loom binary as embedded Luce source, so `loom edit` needs no paths.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Luce: the language — lexer through IR, interpreter, .lc format.
    const luce = b.addModule("luce", .{
        .root_source_file = b.path("src/luce/luce.zig"),
        .target = target,
        .optimize = optimize,
    });
    const luce_tests = b.addTest(.{ .root_module = luce });
    const run_luce_tests = b.addRunArtifact(luce_tests);
    const test_step = b.step("test", "Run the Luce and loom test suites");
    test_step.dependOn(&run_luce_tests.step);

    // File access shared by both executables (import loader, whole-
    // file read/write) — one copy, no drift.
    const app_files = b.createModule(.{
        .root_source_file = b.path("src/apps/files.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "luce", .module = luce },
        },
    });

    // The luce compiler executable.
    const compiler_module = b.createModule(.{
        .root_source_file = b.path("src/apps/luce/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "luce", .module = luce },
            .{ .name = "files", .module = app_files },
        },
    });
    const compiler = b.addExecutable(.{ .name = "luce", .root_module = compiler_module });
    const install_compiler = b.addInstallArtifact(compiler, .{
        .dest_dir = .{ .override = .prefix },
    });
    b.getInstallStep().dependOn(&install_compiler.step);
    const compiler_tests = b.addTest(.{ .root_module = compiler_module });
    test_step.dependOn(&b.addRunArtifact(compiler_tests).step);

    // The loom terminal, with the editor source embedded.
    const terminal_module = b.createModule(.{
        .root_source_file = b.path("src/apps/loom/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "luce", .module = luce },
            .{ .name = "files", .module = app_files },
        },
    });
    terminal_module.addAnonymousImport("editor.luc", .{
        .root_source_file = b.path("programs/editor.luc"),
    });
    const terminal = b.addExecutable(.{ .name = "loom", .root_module = terminal_module });
    const install_terminal = b.addInstallArtifact(terminal, .{
        .dest_dir = .{ .override = .prefix },
    });
    b.getInstallStep().dependOn(&install_terminal.step);
    const terminal_tests = b.addTest(.{ .root_module = terminal_module });
    test_step.dependOn(&b.addRunArtifact(terminal_tests).step);

    // Compile the bundled Luce programs with the freshly built luce.
    // `deps` lists imported sibling modules so edits to them re-run
    // the compile even though only the root file is an argument.
    const bundled = [_]struct { name: []const u8, deps: []const []const u8 = &.{} }{
        .{ .name = "hello" },
        .{ .name = "editor" },
        .{ .name = "sort" },
        .{ .name = "bf" },
        .{ .name = "wordcount" },
        .{ .name = "life" },
        .{ .name = "calc" },
        .{ .name = "stats", .deps = &.{"mathx"} },
    };
    for (bundled) |program| {
        const compile_program = b.addRunArtifact(compiler);
        compile_program.addArg("build");
        compile_program.addFileArg(b.path(b.fmt("programs/{s}.luc", .{program.name})));
        compile_program.addArg("-o");
        const module_file = compile_program.addOutputFileArg(b.fmt("{s}.lc", .{program.name}));
        for (program.deps) |dependency| {
            compile_program.addFileInput(b.path(b.fmt("programs/{s}.luc", .{dependency})));
        }
        const install_module = b.addInstallFile(
            module_file,
            b.fmt("programs/{s}.lc", .{program.name}),
        );
        b.getInstallStep().dependOn(&install_module.step);
    }
}
