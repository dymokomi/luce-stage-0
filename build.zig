const std = @import("std");
const builtin = @import("builtin");

// LuciaOS v2 builds two executables from one language module:
//
//   luce  — the compiler (.luc source in, a native .lc out)
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
    // Installed rather than only built, and named here, because the
    // bundled programs below are linked against the *installed* copy:
    // compiling one is a link, and a link needs a library on a path
    // `luce` can find (`apps/native.zig`, `LUCE_LIB`).
    const install_runtime = b.addInstallArtifact(runtime_library, .{});
    b.getInstallStep().dependOn(&install_runtime.step);

    // Luce: the language — lexer through IR lowering, the interpreter,
    // the .lc format.  It links nothing: `08_llvm/lower.zig` builds
    // LLVM IR with `std.zig.llvm.Builder`, which is pure Zig.
    const luce = b.addModule("luce", .{
        .root_source_file = b.path("src/luce/luce.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // What produced an artifact's machine code, as one number both
    // binaries carry (`generatorIdentity` below).  `08_llvm/lower.zig`
    // stamps it into every artifact's tag and every loader checks it,
    // so a `luce` and a `loom` from one build agree, and a `.lc` some
    // earlier build left beside a program is refused rather than run.
    // It belongs to the language module because both halves of that
    // deal live there: the tag is written in `08_llvm` and read in
    // `08_llvm/abi.zig`, which is all loom needs to link.
    const generator = b.addOptions();
    generator.addOption(u64, "generator", generatorIdentity(b, target, optimize, llvm));
    luce.addOptions("build_options", generator);

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

    // The executable specification (`src/luce/specs.zig`): every test
    // that runs a Luce program, run on both engines and compared.
    //
    // It is a module of its own because it is the only one that needs
    // both halves — `luce` for the interpreter that acts as the
    // differential oracle, `emit` for the machine code that actually
    // ships (docs/ENGINE.md).  Keeping it out of `luce` is what keeps
    // libLLVM out of everything the specification does not need it
    // for.
    const specs = b.createModule(.{
        .root_source_file = b.path("src/luce/specs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "luce", .module = luce },
            .{ .name = "emit", .module = emit },
        },
    });

    // The flagship program, as bytes the specification can run.  A
    // build-system import rather than a relative `@embedFile`, for the
    // reason `loom`'s shell takes one: a spec that pinned its own
    // inline copy of the editor would pin nothing.
    specs.addAnonymousImport("editor.luc", .{
        .root_source_file = b.path("programs/editor.luc"),
    });

    // The five files of the adventure engine, for the same reason and
    // by the same road: a spec that drives the game has to drive the
    // one that ships, and this one is a *project* — the root and the
    // four modules it imports all go in, because `agree.project`
    // compiles them together the way `luce build` does.
    for ([_][]const u8{ "adventure", "world", "story", "command", "journal" }) |program_file| {
        specs.addAnonymousImport(b.fmt("{s}.luc", .{program_file}), .{
            .root_source_file = b.path(b.fmt("programs/{s}.luc", .{program_file})),
        });
    }

    // Where the specification finds the library to link a compiled
    // program against.  A path rather than a linked dependency: the
    // harness drives `cc` itself, because the link is part of what it
    // proves.
    const runtime_path = b.addOptions();
    runtime_path.addOptionPath("luce_rt_library", runtime_library.getEmittedBin());
    specs.addOptions("build_options", runtime_path);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = specs })).step);

    // The documentation site's generator (`site/src/`).  Its tests are
    // what keep the word tables it highlights with, its link resolver
    // and its Markdown honest, and they belong in `zig build test`
    // rather than only in `site/build.sh`: a change to the language
    // that the site has to follow should fail here, on the commit that
    // made it, not on whoever next builds the site.
    //
    // It imports nothing — not `luce`, and so not libLLVM.  The
    // generator drives the built binaries as subprocesses instead of
    // linking the language in, which is what lets it verify what the
    // toolchain actually does rather than what a linked copy would.
    const site_generator = b.createModule(.{
        .root_source_file = b.path("site/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = site_generator })).step);

    // The editor grammar's generator (`tools/grammar.zig`).  Unlike the
    // site generator above it *does* import `luce`: it verifies nothing
    // about a running program, it turns the compiler's word tables into
    // one JSON file, so reading the tables directly is both simpler and
    // the whole point — the committed grammar spent a release cycle
    // highlighting builtins the language had deleted, because it was a
    // copy and nothing checked it.
    //
    // `zig build grammar` rewrites the committed file; the test in the
    // module compares the two and fails the suite when they differ, so
    // a language change that forgets the grammar cannot land quietly.
    // The guard on docs/TYPES.md's rename: no Luce source anywhere in
    // the tree may still spell a builtin type the retired way.  It
    // reads the repository rather than the compiler, so it imports
    // nothing and runs from the root the way the grammar pin does.
    const spelling_guard = b.createModule(.{
        .root_source_file = b.path("tools/spelling.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = spelling_guard })).step);

    // The guard on the documentation: every Luce sample in every living
    // document is compiled by the compiler this build just made
    // (`tools/doccheck.zig`).  It imports `luce` for the same reason
    // the grammar generator does — it asks the front end a question
    // rather than watching a program run, so linking the language in is
    // both simpler and the point.  A document that shows code which
    // does not compile fails `zig build test`, not only `site/build.sh`.
    const documentation_guard = b.createModule(.{
        .root_source_file = b.path("tools/doccheck.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "luce", .module = luce },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = documentation_guard })).step);

    const grammar_generator = b.createModule(.{
        .root_source_file = b.path("tools/grammar.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "luce", .module = luce },
        },
    });
    // The corpus the grammar is tested against sits above the tool's
    // module root, and `@embedFile` does not leave a module — so it
    // arrives under a name instead.
    grammar_generator.addAnonymousImport("editor.luc", .{
        .root_source_file = b.path("programs/editor.luc"),
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = grammar_generator })).step);

    const grammar_tool = b.addExecutable(.{
        .name = "luce-grammar",
        .root_module = grammar_generator,
    });
    const run_grammar = b.addRunArtifact(grammar_tool);
    const grammar_file = run_grammar.addOutputFileArg("luce.tmLanguage.json");
    const write_grammar = b.addUpdateSourceFiles();
    write_grammar.addCopyFileToSource(grammar_file, "tools/vscode-luce/syntaxes/luce.tmLanguage.json");
    const grammar_step = b.step(
        "grammar",
        "Regenerate the VS Code TextMate grammar from the language's tables",
    );
    grammar_step.dependOn(&write_grammar.step);

    // stdout and stderr, opened the same way by all three binaries —
    // `luce`, `loom`, and the `main` a compiled program links — so a
    // program's output does not depend on who started it.
    const app_streams = b.createModule(.{
        .root_source_file = b.path("src/apps/streams.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = app_streams })).step);

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
            // For the one durable whole-file write there is: an object
            // a caller will see is published atomically and synced,
            // like everything else that reaches a name a loader reads.
            .{ .name = "files", .module = app_files },
        },
    });
    const native_tests = b.addTest(.{ .root_module = app_native });
    test_step.dependOn(&b.addRunArtifact(native_tests).step);

    // The one rule that keeps a program's own text from forging the
    // terminal (`src/apps/sanitize.zig`).  Its own module because it
    // has two unrelated consumers — the host's frame buffer, which
    // allocates, and a trap report, which must not — and there has to
    // be one answer to "what counts as safe".  It imports nothing.
    const app_sanitize = b.createModule(.{
        .root_source_file = b.path("src/apps/sanitize.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = app_sanitize })).step);

    // How a run ended, said and scored: one rendering of a trap, an
    // uncaught error and a leak census, and one exit table, for every
    // runner (`src/apps/report.zig`).  It touches no terminal and holds
    // no state, which is why loom's runner and the standalone `main`
    // can both reach it without either reaching the other.
    const app_report = b.createModule(.{
        .root_source_file = b.path("src/apps/report.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "luce", .module = luce },
            .{ .name = "sanitize", .module = app_sanitize },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = app_report })).step);

    // The real host — console, cwd-relative files, arguments, the
    // terminal — as the ABI's C table, which is the one shape a
    // compiled program asks for anything through.  Shared by loom and
    // by the standalone `main` below, so a compiled program sees the
    // same world whichever runner started it.
    const app_host = b.createModule(.{
        .root_source_file = b.path("src/apps/host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "luce", .module = luce },
            .{ .name = "report", .module = app_report },
            .{ .name = "sanitize", .module = app_sanitize },
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
                .{ .name = "report", .module = app_report },
                .{ .name = "streams", .module = app_streams },
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
            .{ .name = "streams", .module = app_streams },
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

    // The miniature install tree both product suites drive
    // (`src/apps/harness.zig`).  Test-only, and shared because it was
    // written twice and the second copy had already drifted; it has no
    // tests of its own, because a broken harness fails both suites.
    const app_harness = b.createModule(.{
        .root_source_file = b.path("src/apps/harness.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The compiler at its command line, and the standalone binary it
    // writes (`src/apps/luce/product.zig`).
    //
    // Its own module for the reason the pair's is: it names the `luce`
    // binary, and a module that named the binary built from it would
    // be a cycle in the build graph.  What it needs is that binary and
    // the two static libraries an install tree carries, because it
    // builds one and uses it exactly as a person would.
    const compiler_product = b.createModule(.{
        .root_source_file = b.path("src/apps/luce/product.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "harness", .module = app_harness },
        },
    });
    const compiler_pieces = b.addOptions();
    compiler_pieces.addOptionPath("luce_binary", compiler.getEmittedBin());
    compiler_pieces.addOptionPath("luce_rt_library", runtime_library.getEmittedBin());
    compiler_pieces.addOptionPath("luce_start_library", start_library.getEmittedBin());
    compiler_product.addOptions("build_options", compiler_pieces);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = compiler_product })).step);

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
            .{ .name = "report", .module = app_report },
            .{ .name = "streams", .module = app_streams },
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
        // For the two facts a test of the *outside* still has to know
        // exactly: what a serialized module is called, and what an
        // artifact's tag says about itself.
        .imports = &.{
            .{ .name = "luce", .module = luce },
            .{ .name = "harness", .module = app_harness },
        },
    });
    const binaries = b.addOptions();
    binaries.addOptionPath("loom_binary", terminal.getEmittedBin());
    binaries.addOptionPath("luce_binary", compiler.getEmittedBin());
    binaries.addOptionPath("luce_rt_library", runtime_library.getEmittedBin());
    product_module.addOptions("build_options", binaries);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = product_module })).step);

    // The userland program the pair exists to run, proved end to end:
    // a real ZIP archive on a real disk, listed, extracted and built
    // again by `programs/zipper.luc` through both installed binaries.
    //
    // A module of its own beside `product.zig` for the same reason
    // that file is one — it names the binaries — and apart from it
    // because it proves a different thing: `product.zig` is the
    // loom→luce hand-off, this is userland over `std.zip` and
    // `std.files`.  The program comes in by build-system import so the
    // test pins the file that ships.
    const zipping_module = b.createModule(.{
        .root_source_file = b.path("src/apps/loom/zipping.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "harness", .module = app_harness },
        },
    });
    zipping_module.addAnonymousImport("zipper.luc", .{
        .root_source_file = b.path("programs/zipper.luc"),
    });
    zipping_module.addOptions("build_options", binaries);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = zipping_module })).step);

    // Compile the bundled Luce programs with the freshly built luce.
    // `deps` lists imported sibling modules so edits to them re-run
    // the compile even though only the root file is an argument.
    //
    // **A `.lc` is machine code, so this is a link** (docs/ENGINE.md):
    // installing needs a C toolchain and the runtime library, not only
    // the compiler.  `LUCE_LIB` points at the install tree's `lib/`,
    // which is where `luce` would look for it anyway, and the library
    // is a file input so a change to the runtime rebuilds every
    // program that carries a copy of it.
    const runtime_directory = b.getInstallPath(.lib, "");
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
        .{ .name = "zipper" },
        .{ .name = "adventure", .deps = &.{ "world", "story", "command", "journal" } },
    };
    for (bundled) |program| {
        const compile_program = b.addRunArtifact(compiler);
        compile_program.addArg("build");
        compile_program.addFileArg(b.path(b.fmt("programs/{s}.luc", .{program.name})));
        compile_program.addArg("-o");
        const artifact_file = compile_program.addOutputFileArg(b.fmt("{s}.lc", .{program.name}));
        for (program.deps) |dependency| {
            compile_program.addFileInput(b.path(b.fmt("programs/{s}.luc", .{dependency})));
        }
        linkAgainstRuntime(compile_program, install_runtime, runtime_directory, runtime_library);
        const install_program = b.addInstallFile(
            artifact_file,
            b.fmt("programs/{s}.lc", .{program.name}),
        );
        b.getInstallStep().dependOn(&install_program.step);
        // `zig build test` compiles every bundled program too, so a
        // broken userland program fails the suite — not only a full
        // ./build.sh install.
        test_step.dependOn(&compile_program.step);
    }

    // The benchmark programs compile under test too, so bench/*.luc
    // cannot rot; timing them stays manual (bench/run.sh).  Every name
    // bench/run.sh times is here — a guard that covers all but one
    // leaves one that can rot in silence.
    const benches = [_][]const u8{
        "loops",
        "math",
        "strings",
        "arrays",
        "arrays32",
        "matmul",
        "matmul32",
        "stats",
        "lists",
    };
    for (benches) |name| {
        const compile_bench = b.addRunArtifact(compiler);
        compile_bench.addArg("build");
        compile_bench.addFileArg(b.path(b.fmt("bench/{s}.luc", .{name})));
        compile_bench.addArg("-o");
        _ = compile_bench.addOutputFileArg(b.fmt("{s}.lc", .{name}));
        linkAgainstRuntime(compile_bench, install_runtime, runtime_directory, runtime_library);
        test_step.dependOn(&compile_bench.step);
    }
}

/// Give one `luce build` run what it needs to link: the installed
/// runtime library on `LUCE_LIB`, the install ordered before the
/// compile, and the library itself as an input so the cached result is
/// thrown away when the runtime changes.
fn linkAgainstRuntime(
    run: *std.Build.Step.Run,
    install_runtime: *std.Build.Step.InstallArtifact,
    directory: []const u8,
    runtime_library: *std.Build.Step.Compile,
) void {
    run.setEnvironmentVariable("LUCE_LIB", directory);
    run.step.dependOn(&install_runtime.step);
    run.addFileInput(runtime_library.getEmittedBin());
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
    /// `--version` and `--host-target`.  Nothing links against these:
    /// they name the optimizer that turns the lowering's bitcode into
    /// instructions, and the host triple `emit.hostTriple` will ask the
    /// same library for, so they belong to the code generator's
    /// identity below.
    version: []const u8,
    host_target: []const u8,
};

fn discoverLlvm(b: *std.Build) Llvm {
    const configured = b.option(
        []const u8,
        "llvm-config",
        "Path to llvm-config (default: found on PATH or in the usual prefixes)",
    );
    // `./vendor-llvm.sh` builds a pinned LLVM statically into
    // .llvm/install.  Prefer it when it is there: it is the version
    // this compiler is tested against, and linking it leaves `luce`
    // depending on no LLVM the machine happens to have.  A system
    // LLVM stays supported, and -Dllvm-config still wins over both.
    const vendored_relative = ".llvm/install/bin/llvm-config";
    const vendored = b.pathFromRoot(vendored_relative);
    const program = configured orelse
        if (b.build_root.handle.access(b.graph.io, vendored_relative, .{})) |_| vendored else |_| b.findProgram(
            &.{ "llvm-config", "llvm-config-22", "llvm-config-21", "llvm-config-20" },
            &.{ "/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin", "/usr/lib/llvm/bin" },
        ) catch std.process.fatal(
            \\cannot find llvm-config.
            \\
            \\`luce` compiles through LLVM in-process (docs/CODEGEN.md),
            \\so libLLVM and its headers must be available.  Either build
            \\the pinned one statically:
            \\
            \\    ./vendor-llvm.sh
            \\
            \\or install a system LLVM (macOS: `brew install llvm`;
            \\Debian/Ubuntu: `apt install llvm-dev`), or point the build
            \\at one you already have:
            \\
            \\    zig build -Dllvm-config=/path/to/llvm-config
            \\
            \\`loom` links no LLVM, so a machine that only runs Luce
            \\programs needs none of this.
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
        .version = ask(b, program, "--version"),
        .host_target = ask(b, program, "--host-target"),
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

// ---------------------------------------------------------------------------
// The code generator's identity
// ---------------------------------------------------------------------------

/// The barrels and directories whose contents decide what machine code
/// an artifact ends up holding: the lowering and the emitter, and the
/// runtime library the link puts inside it.  Everything else about a
/// compiled program — every stage from the lexer to the IR verifier —
/// reaches the artifact only as the serialized module, which the tag
/// already hashes as `source_hash`.
const generator_barrels = [_][]const u8{
    "src/luce/08_llvm.zig",
    "src/luce/runtime.zig",
};
const generator_trees = [_][]const u8{
    "src/luce/08_llvm",
    "src/luce/runtime",
};

/// What produced an artifact's machine code, as one number.
///
/// An artifact is a cache entry, and `source_hash` keys it on the program
/// alone: change the code generator and every artifact already sitting
/// beside a program keeps running the instructions the *previous* one
/// wrote, silently, because the `.lc` still re-encodes to the same
/// bytes.  This is the other half of the key.
///
/// **It is computed rather than declared.**  A hand-bumped number is
/// the same shape as `abi.version`, but an ABI changes a few times a
/// year and a code generator changes every day — and forgetting to
/// bump it is precisely how an artifact goes stale unnoticed.  So the
/// identity is a content hash of everything that decides the answer,
/// taken here because `build.zig` is the one place that sees all of
/// it: the sources below, the Zig and the settings that compile them,
/// and the LLVM that optimizes what they emit.
///
/// **Content, never a clock.**  Nothing here reads an mtime or a path,
/// so a rebuilt-but-identical toolchain produces the identical number
/// and every artifact on disk stays valid — which is the property that
/// makes the cache a cache.  `docs/CODEGEN.md` records what it
/// therefore covers and what it does not.
fn generatorIdentity(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    llvm: Llvm,
) u64 {
    var identity = std.hash.Wyhash.init(0x4c554347); // "LUCG"

    // How the sources below are turned into code.  libluce_rt is
    // linked into every artifact, so the Zig that built it, the
    // optimize mode it was built at, and the machine it was built for
    // are all part of what the artifact holds.
    identity.update(builtin.zig_version_string);
    identity.update(@tagName(optimize));
    identity.update(target.result.zigTriple(b.allocator) catch @panic("OOM"));
    identity.update(target.result.cpu.model.name);
    identity.update(std.mem.asBytes(&target.result.cpu.features.ints));

    // The optimizer that turns the lowering's bitcode into
    // instructions, and the host triple `emit.hostTriple` asks the same
    // library for.  A version string rather than the library's bytes:
    // it is hundreds of megabytes and this runs on every configure.
    identity.update(llvm.version);
    identity.update(llvm.host_target);

    for (generator_barrels) |path| hashSource(b, &identity, path);
    for (generator_trees) |root| hashTree(b, &identity, root);
    return identity.final();
}

/// One file's name and bytes, folded in.  The name counts: a renamed
/// file is a different generator even when nothing inside it moved.
fn hashSource(b: *std.Build, identity: *std.hash.Wyhash, path: []const u8) void {
    const bytes = b.build_root.handle.readFileAlloc(
        b.graph.io,
        path,
        b.allocator,
        .unlimited,
    ) catch |failure| std.process.fatal(
        "cannot read {s}, which the code generator's identity is taken from: {s}",
        .{ path, @errorName(failure) },
    );
    identity.update(path);
    identity.update(std.mem.asBytes(&@as(u64, bytes.len)));
    identity.update(bytes);
}

/// Every `.zig` file under a directory, in name order.
///
/// The whole directory, and not a list of the interesting files in it:
/// a list is a thing to forget, and forgetting is the failure this
/// identity exists to end.  A test file cannot change what a compiled
/// artifact holds, so counting one costs a rebuild that was not
/// needed; leaving out a file that can costs a wrong answer.
fn hashTree(b: *std.Build, identity: *std.hash.Wyhash, root: []const u8) void {
    var directory = b.build_root.handle.openDir(
        b.graph.io,
        root,
        .{ .iterate = true },
    ) catch |failure| std.process.fatal(
        "cannot open {s}, which the code generator's identity is taken from: {s}",
        .{ root, @errorName(failure) },
    );
    defer directory.close(b.graph.io);

    var found: std.ArrayList([]const u8) = .empty;
    var walk = directory.walk(b.allocator) catch @panic("OOM");
    defer walk.deinit();
    while (walk.next(b.graph.io) catch |failure| std.process.fatal(
        "cannot read {s}, which the code generator's identity is taken from: {s}",
        .{ root, @errorName(failure) },
    )) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        found.append(b.allocator, b.pathJoin(&.{ root, entry.path })) catch @panic("OOM");
    }

    // A walk's order is the file system's and is undefined; the
    // identity's has to be the same on every machine that reads the
    // same tree.
    std.mem.sort([]const u8, found.items, {}, beforeByName);
    for (found.items) |path| hashSource(b, identity, path);
}

fn beforeByName(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
