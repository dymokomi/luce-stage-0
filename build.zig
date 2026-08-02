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

    // libLLVM is a hard dependency of the language module: the one
    // code generator calls it in-process (docs/CODEGEN.md).  Both
    // executables carry it, because loom compiles too (`loom luce
    // FILE.luc`, and the shell accepts bare .luc paths).
    const llvm = discoverLlvm(b);

    // libluce_rt: Luce's semantics as a linkable library — the object
    // heap, ownership, containers, strings, conversions (docs/
    // CODEGEN.md).  Every compiled artifact links it, so it is built
    // as a real static library and installed beside the binaries; the
    // language module below reaches the same source directly, which is
    // how the interpreter and compiled code stay one implementation.
    const runtime_library = b.addLibrary(.{
        .name = "luce_rt",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/luce/runtime.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(runtime_library);

    // Luce: the language — lexer through IR, the interpreter, the
    // LLVM backend, the .lc format.
    const luce = b.addModule("luce", .{
        .root_source_file = b.path("src/luce/luce.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkLlvm(luce, llvm);

    // Where the codegen tests find the library to link a compiled
    // program against.  A path rather than a linked dependency: the
    // test drives `cc` itself, because the link is part of what it
    // proves.
    const runtime_path = b.addOptions();
    runtime_path.addOptionPath("luce_rt_library", runtime_library.getEmittedBin());
    luce.addOptions("build_options", runtime_path);
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
    const app_files_tests = b.addTest(.{ .root_module = app_files });
    test_step.dependOn(&b.addRunArtifact(app_files_tests).step);

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
        .{ .name = "dice" },
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
        // `zig build test` compiles every bundled program too, so a
        // broken userland program fails the suite — not only a full
        // ./build.sh install.
        test_step.dependOn(&compile_program.step);
    }

    // The benchmark programs compile under test too, so bench/*.luc
    // cannot rot; timing them stays manual (bench/run.sh).
    const benches = [_][]const u8{ "loops", "math", "strings", "arrays", "matmul", "stats" };
    for (benches) |name| {
        const compile_bench = b.addRunArtifact(compiler);
        compile_bench.addArg("build");
        compile_bench.addFileArg(b.path(b.fmt("bench/{s}.luc", .{name})));
        compile_bench.addArg("-o");
        _ = compile_bench.addOutputFileArg(b.fmt("{s}.lc", .{name}));
        test_step.dependOn(&compile_bench.step);
    }
}

// ---------------------------------------------------------------------------
// libLLVM discovery
// ---------------------------------------------------------------------------

/// Where an installed LLVM keeps its headers, its library, and what
/// that library needs alongside it.  Everything is discovered by
/// asking `llvm-config`, so a Homebrew, distribution, or hand-built
/// LLVM all work without editing this file.
const Llvm = struct {
    include_dir: []const u8,
    lib_dir: []const u8,
    /// Library names, without the leading `-l`.
    libraries: []const []const u8,
    /// Absolute paths `llvm-config` handed back instead of `-l` names.
    objects: []const []const u8,
    /// The C++ runtime LLVM was built against ("c++" or "stdc++").
    cxx_runtime: []const u8,
};

fn discoverLlvm(b: *std.Build) Llvm {
    const configured = b.option(
        []const u8,
        "llvm-config",
        "Path to llvm-config (default: found on PATH or in the usual prefixes)",
    );
    const program = configured orelse b.findProgram(
        &.{ "llvm-config", "llvm-config-22", "llvm-config-21", "llvm-config-20" },
        &.{ "/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin", "/usr/lib/llvm/bin" },
    ) catch std.process.fatal(
        \\cannot find llvm-config.
        \\
        \\Luce compiles through LLVM in-process (docs/CODEGEN.md), so
        \\libLLVM and its headers must be installed.  Install LLVM
        \\(macOS: `brew install llvm`; Debian/Ubuntu: `apt install
        \\llvm-dev`) or point the build at it:
        \\
        \\    zig build -Dllvm-config=/path/to/llvm-config
        \\
    , .{});

    const cxx_flags = ask(b, program, "--cxxflags");
    const linked = [_][]const u8{
        ask(b, program, "--libs"),
        ask(b, program, "--system-libs"),
    };
    return .{
        .include_dir = ask(b, program, "--includedir"),
        .lib_dir = ask(b, program, "--libdir"),
        .libraries = splitLinkerFlags(b, &linked, .names),
        .objects = splitLinkerFlags(b, &linked, .paths),
        .cxx_runtime = if (std.mem.indexOf(u8, cxx_flags, "-stdlib=libc++") != null)
            "c++"
        else
            "stdc++",
    };
}

/// One `llvm-config` query, trimmed.
fn ask(b: *std.Build, program: []const u8, question: []const u8) []const u8 {
    var code: u8 = undefined;
    const answered = b.runAllowFail(&.{ program, question }, &code, .inherit) catch
        std.process.fatal("`{s} {s}` failed; is the LLVM installation complete?", .{ program, question });
    return std.mem.trim(u8, answered, " \t\r\n");
}

/// `llvm-config` answers in linker-flag form: `-lLLVM-22` for a library
/// name, an absolute path for anything it cannot name.  Split the
/// answers into whichever of the two the caller wants.
fn splitLinkerFlags(
    b: *std.Build,
    answers: []const []const u8,
    wanted: enum { names, paths },
) []const []const u8 {
    var collected: std.ArrayList([]const u8) = .empty;
    for (answers) |answer| {
        var remaining = std.mem.tokenizeAny(u8, answer, " \t\r\n");
        while (remaining.next()) |flag| {
            const is_name = std.mem.startsWith(u8, flag, "-l");
            switch (wanted) {
                .names => if (is_name) collected.append(b.allocator, flag[2..]) catch @panic("OOM"),
                .paths => if (!is_name and std.fs.path.isAbsolute(flag)) {
                    collected.append(b.allocator, flag) catch @panic("OOM");
                },
            }
        }
    }
    return collected.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn linkLlvm(module: *std.Build.Module, llvm: Llvm) void {
    module.addIncludePath(.{ .cwd_relative = llvm.include_dir });
    module.addLibraryPath(.{ .cwd_relative = llvm.lib_dir });
    for (llvm.libraries) |name| module.linkSystemLibrary(name, .{});
    for (llvm.objects) |path| module.addObjectFile(.{ .cwd_relative = path });
    module.linkSystemLibrary(llvm.cxx_runtime, .{});
    module.link_libc = true;
}
