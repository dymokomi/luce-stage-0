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
//
// **Only `luce` links libLLVM, and that is a decision about what the
// two binaries are.**  libLLVM is 164 MB; dyld maps and binds it before
// `main` on every invocation that names it, at a measured 5.7 ms even
// when no LLVM function is ever called.  loom's job is starting
// programs, so it must not pay that — when it needs one compiled it
// runs the `luce` binary (`apps/loom/runner.zig`).  The dependency is
// confined to the `emit` module below, and a machine that only runs
// Luce programs needs no LLVM installed at all.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // Luce: the language — lexer through IR lowering, the interpreter,
    // the .lc format.  It links nothing: `08_llvm/lower.zig` builds
    // LLVM IR with `std.zig.llvm.Builder`, which is pure Zig.
    const luce = b.addModule("luce", .{
        .root_source_file = b.path("src/luce/luce.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const luce_tests = b.addTest(.{ .root_module = luce });
    const run_luce_tests = b.addRunArtifact(luce_tests);
    const test_step = b.step("test", "Run the Luce and loom test suites");
    test_step.dependOn(&run_luce_tests.step);

    // The one module that calls libLLVM: bitcode in, object code out
    // (`src/luce/08_llvm/emit.zig`).  It carries the backend's
    // end-to-end proof too, because that test is the one thing that
    // takes Luce source all the way into a loaded shared library.
    const emit = b.addModule("emit", .{
        .root_source_file = b.path("src/luce/08_llvm/emit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "luce", .module = luce },
        },
    });
    linkLlvm(emit, llvm);

    // Where that proof finds the library to link a compiled program
    // against.  A path rather than a linked dependency: the test drives
    // `cc` itself, because the link is part of what it proves.
    const runtime_path = b.addOptions();
    runtime_path.addOptionPath("luce_rt_library", runtime_library.getEmittedBin());
    emit.addOptions("build_options", runtime_path);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = emit })).step);

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

    const app_files_tests = b.addTest(.{ .root_module = app_files });
    test_step.dependOn(&b.addRunArtifact(app_files_tests).step);

    // Finding the tools, linking an object, loading an artifact — and
    // finding the `luce` binary, which is how loom gets something
    // built.  Shared by both executables and linking nothing itself;
    // the half that needs a code generator is `apps/luce/object.zig`.
    const app_native = b.createModule(.{
        .root_source_file = b.path("src/apps/native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "luce", .module = luce },
        },
    });
    const native_tests = b.addTest(.{ .root_module = app_native });
    test_step.dependOn(&b.addRunArtifact(native_tests).step);

    // The real host — console, cwd-relative files, arguments, the
    // terminal — offered twice over one implementation: as
    // `backend.Host` for the interpreter and as the ABI's C table for
    // compiled code.  Shared by loom and by the standalone `main`
    // below, so a compiled program sees the same world whichever
    // runner started it.
    const app_host = b.createModule(.{
        .root_source_file = b.path("src/apps/host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "luce", .module = luce },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = app_host })).step);

    // libluce_start: `main` for a compiled program, so `luce build
    // --emit=exe` is one `cc` invocation over three files (the
    // program's object, this, and libluce_rt).  Installed beside the
    // runtime library, and found the same way (`apps/native.zig`).
    const start_library = b.addLibrary(.{
        .name = "luce_start",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/start.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "luce", .module = luce },
                .{ .name = "host", .module = app_host },
            },
        }),
    });
    b.installArtifact(start_library);

    // The luce compiler executable: the one binary with a code
    // generator in it, and so the one that links libLLVM.
    const compiler_module = b.createModule(.{
        .root_source_file = b.path("src/apps/luce/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "luce", .module = luce },
            .{ .name = "files", .module = app_files },
            .{ .name = "native", .module = app_native },
            .{ .name = "emit", .module = emit },
        },
    });

    // Where `apps/luce/object.zig`'s tests find the two libraries a
    // real link needs.  They drive `cc` exactly as the shipped code
    // does — the point of those tests is that the *product* path
    // links, loads and runs, not that a private one does.
    const installed_libraries = b.addOptions();
    installed_libraries.addOptionPath("luce_rt_library", runtime_library.getEmittedBin());
    installed_libraries.addOptionPath("luce_start_library", start_library.getEmittedBin());
    compiler_module.addOptions("build_options", installed_libraries);

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
            .{ .name = "host", .module = app_host },
            .{ .name = "native", .module = app_native },
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

    // The shipped pair, proved together: loom compiling a program by
    // running luce, and refusing to when there is no luce to run.
    //
    // Its own module, and it has to be: it names both binaries, and a
    // module that named the binary built from it would be a cycle in
    // the build graph.
    const product_module = b.createModule(.{
        .root_source_file = b.path("src/apps/loom/product.zig"),
        .target = target,
        .optimize = optimize,
    });
    const binaries = b.addOptions();
    binaries.addOptionPath("loom_binary", terminal.getEmittedBin());
    binaries.addOptionPath("luce_binary", compiler.getEmittedBin());
    binaries.addOptionPath("luce_rt_library", runtime_library.getEmittedBin());
    product_module.addOptions("build_options", binaries);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = product_module })).step);

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
