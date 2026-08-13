const std = @import("std");
const builtin = @import("builtin");

/// termui's modules, entry module first (docs/TERMUI.md D12).  The
/// package is userland, and three things in this file need to name its
/// files: the editor's compiles (it imports them), the specs (they
/// compile the editor), and the package's own test run.
const termui_version = "0.1.0";
const termui_modules = [_][]const u8{ "termui", "screen", "events", "border", "rows" };

// LuciaOS v2 builds two executables from one language module:
//
//   luce  — the compiler (.luc source in, a native .lc out)
//   loom  — the terminal that runs compiled Luce programs
//
// zig build installs both plus the compiled bundled programs
// (examples/*/*.luc -> PREFIX/examples/*/*.lc); zig build test runs the
// language suite and both app suites.  The editor is one of those
// bundled programs and is installed as a standalone `editor` binary
// too — loom carries no editor of its own (owner, 2026-08-12).
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
    const project_version = readProjectVersion(b);

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
            // This archive is linked into the shared .lc artifact.
            .pic = true,
        }),
    });
    // The final .lc/exe link is driven by the host's `cc`.  Apple's
    // link resolves everything the archive needs; a Linux `cc` supplies
    // libgcc and glibc but not the compiler-ABI symbols only Zig's
    // compiler-rt defines (`__zig_probe_stack`, and the half-float
    // conversions older libgccs lack), so there the archive must carry
    // compiler-rt or the link is broken.
    const bundles_compiler_rt = target.result.os.tag != .macos;
    runtime_library.bundle_compiler_rt = bundles_compiler_rt;

    // A bundled compiler-rt also defines the C library's public names
    // — memcpy, memset, bcmp, and the whole libm surface — and a
    // definition in a linked archive beats the dynamic libc, so every
    // artifact would trade the platform's optimized routines for
    // generic ones: measured at +52% strings, +58% lists, +65% stats
    // when it happened on macOS (docs/CODEGEN.md, "The benchmark
    // snapshot").  `tools/localize_rt.zig` confines the bundle to the
    // compiler's own namespace — `__*` and `luce_rt_*` stay global,
    // libc's names go local — using the LLVM tools that install
    // beside the `llvm-config` found above, so bundling supplies
    // exactly the missing builtins and can shadow nothing.
    const runtime_archive: std.Build.LazyPath = if (bundles_compiler_rt) confined: {
        const localize = b.addExecutable(.{
            .name = "localize_rt",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/localize_rt.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        const confine = b.addRunArtifact(localize);
        confine.addArg(b.pathJoin(&.{ llvm.bin_dir, "llvm-nm" }));
        confine.addArg(b.pathJoin(&.{ llvm.bin_dir, "llvm-objcopy" }));
        confine.addFileArg(runtime_library.getEmittedBin());
        break :confined confine.addOutputFileArg("libluce_rt.a");
    } else runtime_library.getEmittedBin();

    // Installed rather than only built, and named here, because the
    // bundled programs below are linked against the *installed* copy:
    // compiling one is a link, and a link needs a library on a path
    // `luce` can find (`apps/native.zig`, `LUCE_LIB`).
    const install_runtime = b.addInstallFile(runtime_archive, "lib/libluce_rt.a");
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
    const test_luce_step = b.step("test-luce", "Run the Luce package and runtime tests");
    test_luce_step.dependOn(&run_luce_tests.step);

    // Keep the property corpus addressable on its own.  The ordinary test
    // step runs the checked-in corpus; this lane is where a developer turns
    // on Zig's coverage-guided fuzzer (`zig build test-fuzz --fuzz=10000`)
    // without making the product and documentation suites part of each fuzz
    // iteration.
    const fuzz_luce = b.createModule(.{
        .root_source_file = b.path("src/luce/luce.zig"),
        .target = target,
        // Zig 0.16's fuzz runner expects release-style error handling; using
        // ReleaseSafe here also keeps generated-input failures reproducible
        // instead of depending on debug-only error-return traces.
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    fuzz_luce.addOptions("build_options", generator);
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_luce, .filters = &.{"fuzz:"} });
    const run_luce_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const test_fuzz_step = b.step("test-fuzz", "Run the Luce fuzz and property corpus");
    test_fuzz_step.dependOn(&run_luce_fuzz_tests.step);

    // The deterministic hardening lane adds the fixed-seed near-miss parser
    // stress test to the corpus.  It is cheap enough for local changes and
    // keeps long-input recovery visibly separate from ordinary unit tests.
    const stress_tests = b.addTest(.{ .root_module = luce, .filters = &.{"near-miss programs"} });
    const run_luce_stress_tests = b.addRunArtifact(stress_tests);
    const test_hardening_step = b.step("test-hardening", "Run deterministic Luce hardening tests");
    test_hardening_step.dependOn(&run_luce_fuzz_tests.step);
    test_hardening_step.dependOn(&run_luce_stress_tests.step);

    // Sanitizer lanes intentionally build a fresh root module instead of
    // relying on a command-line flag being inherited by imported modules.
    // That makes the step's name truthful and keeps the ownership corpus
    // runnable against the exact same package graph as `test-luce`.
    const sanitizer_filters = &.{
        "fixed owner-graph",
        "fuzz: owner graphs",
        "checked owner invariants",
        "failed nested list",
        "failed function-value copies",
        "failed worker graph",
        "a worker result copies",
        "waiting a task is one-shot",
        "cross-runtime moves",
        "fixed worker and resource lifecycle",
        "fuzz: worker and resource lifecycles",
        "list growth keeps every raw capacity",
        "worker acquisition failures",
        "nested resource graph failures",
        "stale handles reject every container",
        "stale file operations trap",
        "failed retaining stores",
        "failed struct replacement consumes",
        "struct replacement rejects",
        "host byte counts are bounded",
        "C scalar lengths counts and tags",
        "C byte pointers reject null",
        "map place rolls every key value",
        "builder growth and snapshots",
        "allocating C doors preserve outputs",
        "allocating C value doors preserve graphs",
        "C file acquisition closes raw handles",
        "the C spawn door rolls worker acquisition",
        "C task wait rolls nested result transfer",
        "C compound value doors preserve destinations",
        "C string slices preserve views",
        "fixed mixed owner-graph seeds",
        "fuzz: mixed owner graphs",
        "blocked worker teardown joins",
    };
    const c_sanitize_luce = b.createModule(.{
        .root_source_file = b.path("src/luce/luce.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
        .sanitize_c = .full,
    });
    c_sanitize_luce.addOptions("build_options", generator);
    const c_sanitize_tests = b.addTest(.{
        .root_module = c_sanitize_luce,
        .filters = sanitizer_filters,
    });
    const test_sanitize_c_step = b.step(
        "test-sanitize-c",
        "Run ownership tests with C undefined-behavior sanitization",
    );
    test_sanitize_c_step.dependOn(&b.addRunArtifact(c_sanitize_tests).step);

    const thread_sanitize_luce = b.createModule(.{
        .root_source_file = b.path("src/luce/luce.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
        .sanitize_thread = true,
    });
    thread_sanitize_luce.addOptions("build_options", generator);
    const thread_sanitize_tests = b.addTest(.{
        .root_module = thread_sanitize_luce,
        .filters = sanitizer_filters,
    });
    const test_sanitize_thread_step = b.step(
        "test-sanitize-thread",
        "Run ownership tests with ThreadSanitizer",
    );
    test_sanitize_thread_step.dependOn(&b.addRunArtifact(thread_sanitize_tests).step);

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

    // The flagship example, as bytes the specification can run.  A
    // build-system import rather than a relative `@embedFile`, for the
    // reason `loom`'s shell takes one: a spec that pinned its own
    // inline copy of the editor would pin nothing.
    specs.addAnonymousImport("editor.luc", .{
        .root_source_file = b.path("examples/editor/editor.luc"),
    });
    specs.addAnonymousImport("editor_model.luc", .{
        .root_source_file = b.path("examples/editor/editor_model.luc"),
    });
    // …and the package it draws through, which `editor_spec.zig`
    // serves to the compile as a store would (docs/PACKAGES.md D4).
    for (termui_modules) |module| {
        specs.addAnonymousImport(b.fmt("termui/{s}.luc", .{module}), .{
            .root_source_file = b.path(b.fmt("packages/termui-0.1.0/{s}.luc", .{module})),
        });
    }

    // The five files of the adventure engine, for the same reason and
    // by the same road: a spec that drives the game has to drive the
    // one that ships, and this one is a *project* — the root and the
    // four modules it imports all go in, because `agree.project`
    // compiles them together the way `luce build` does.
    for ([_][]const u8{ "adventure", "world", "story", "command", "journal" }) |program_file| {
        specs.addAnonymousImport(b.fmt("{s}.luc", .{program_file}), .{
            .root_source_file = b.path(b.fmt("examples/adventure/{s}.luc", .{program_file})),
        });
    }

    // Where the specification finds the library to link a compiled
    // program against.  A path rather than a linked dependency: the
    // harness drives `cc` itself, because the link is part of what it
    // proves.
    const runtime_path = b.addOptions();
    runtime_path.addOptionPath("luce_rt_library", runtime_archive);
    specs.addOptions("build_options", runtime_path);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = specs })).step);

    // Keep the highest-risk function/union composition seam addressable
    // without waiting for the bundled applications.  This is a focused
    // differential specification, not a replacement for the full suite.
    const composition_tests = b.addTest(.{
        .root_module = specs,
        .filters = &.{"a bound method carries a union callback"},
    });
    const test_composition_step = b.step(
        "test-composition",
        "Run the bound-method and union-callback composition spec",
    );
    test_composition_step.dependOn(&b.addRunArtifact(composition_tests).step);

    const exceptional_ownership_tests = b.addTest(.{
        .root_module = specs,
        .filters = &.{
            "S34: catch releases a fallible union result",
            "S34: break and continue release union payloads",
            "an unwaited nested union result is discarded",
            "exit unwinds a union carrying a callback",
            "nested worker errors unwind owned graphs",
            "a worker trap unwinds a nested union graph",
            "worker exit unwinds a nested union graph",
            "discarding a worker error still joins",
        },
    });
    const test_exceptional_ownership_step = b.step(
        "test-exceptional-ownership",
        "Run exceptional-control-flow ownership specifications",
    );
    test_exceptional_ownership_step.dependOn(&b.addRunArtifact(exceptional_ownership_tests).step);

    const resource_composition_tests = b.addTest(.{
        .root_module = specs,
        .filters = &.{
            "a struct composes a union optional task callback",
            "a resource graph survives union optional container give return",
            "a task is consumed exactly once through a union optional field",
            "a struct owns an optional file while a callback consumes its result",
            "self: inout replaces union and optional object fields",
        },
    });
    const test_resource_composition_step = b.step(
        "test-resource-composition",
        "Run resource-bearing struct, union, optional, and callback specifications",
    );
    test_resource_composition_step.dependOn(&b.addRunArtifact(resource_composition_tests).step);

    const function_ownership_tests = b.addTest(.{
        .root_module = specs,
        .filters = &.{
            "a give-taking function is a value, and the call through it needs the verb",
            "a give-taking function value moves its argument when called through the value",
            "a function value in a struct field is called through a grouping",
        },
    });
    const test_function_ownership_step = b.step(
        "test-function-ownership",
        "Run function-value ownership and indirect-call specifications",
    );
    test_function_ownership_step.dependOn(&b.addRunArtifact(function_ownership_tests).step);

    const std_trig_tests = b.addTest(.{
        .root_module = specs,
        .filters = &.{"math: trig refuses angles outside its accuracy domain"},
    });
    const test_std_trig_step = b.step(
        "test-std-trig",
        "Run large-angle standard-library trigonometry regressions",
    );
    test_std_trig_step.dependOn(&b.addRunArtifact(std_trig_tests).step);

    const adventure_tests = b.addTest(.{
        .root_module = specs,
        .filters = &.{"a whole game plays the same, turn for turn, on both engines"},
    });
    const test_adventure_step = b.step(
        "test-adventure",
        "Run the multi-module adventure regression",
    );
    test_adventure_step.dependOn(&b.addRunArtifact(adventure_tests).step);

    // The backend must refuse a function comparison even when a hostile MIR
    // shape bypasses the verifier.  Keep this seam independently runnable:
    // it protects the lowerer's refusal from being hidden by the much larger
    // differential specification.
    const llvm_hardening_tests = b.addTest(.{
        .root_module = specs,
        .filters = &.{"LLVM refuses function equality"},
    });
    const test_llvm_hardening_step = b.step(
        "test-llvm-hardening",
        "Run hostile-MIR LLVM backend hardening tests",
    );
    test_llvm_hardening_step.dependOn(&b.addRunArtifact(llvm_hardening_tests).step);

    // The ownership diagnostic has a source-order contract of its own:
    // advice for one argument may not make a later argument unusable.
    // Keep that regression independently runnable while the full
    // executable specification remains the final gate.
    const ownership_diagnostic_tests = b.addTest(.{
        .root_module = specs,
        .filters = &.{"batch advice does not poison a later occurrence"},
    });
    const test_ownership_diagnostics_step = b.step(
        "test-ownership-diagnostics",
        "Run ownership diagnostics that inspect whole operand batches",
    );
    test_ownership_diagnostics_step.dependOn(&b.addRunArtifact(ownership_diagnostic_tests).step);

    const format_diagnostic_tests = b.addTest(.{
        .root_module = specs,
        .filters = &.{"percent formatting mistake names f-strings"},
    });
    const test_format_diagnostics_step = b.step(
        "test-format-diagnostics",
        "Run diagnostics for string-formatting mistakes",
    );
    test_format_diagnostics_step.dependOn(&b.addRunArtifact(format_diagnostic_tests).step);

    const fstring_tests = b.addTest(.{
        .root_module = specs,
        .filters = &.{"f-strings: empty, no holes, escapes, literal braces"},
    });
    const test_fstrings_step = b.step(
        "test-fstrings",
        "Run f-string whitespace and nested-expression specifications",
    );
    test_fstrings_step.dependOn(&b.addRunArtifact(fstring_tests).step);

    const namespace_diagnostic_tests = b.addTest(.{
        .root_module = luce,
        .filters = &.{"imports are explicit, checked, and reported per file"},
    });
    const test_namespace_diagnostics_step = b.step(
        "test-namespace-diagnostics",
        "Run consistent diagnostics for unimported namespaces",
    );
    test_namespace_diagnostics_step.dependOn(&b.addRunArtifact(namespace_diagnostic_tests).step);

    const worker_exhaustion_tests = b.addTest(.{
        .root_module = luce,
        .filters = &.{
            "worker arena exhaustion crosses the join as out of memory",
            "an interpreter worker marks arena exhaustion before it returns",
        },
    });
    const test_worker_exhaustion_step = b.step(
        "test-worker-exhaustion",
        "Run worker exhaustion propagation regressions",
    );
    test_worker_exhaustion_step.dependOn(&b.addRunArtifact(worker_exhaustion_tests).step);

    const worker_ownership_tests = b.addTest(.{
        .root_module = luce,
        .filters = &.{
            "a worker result copies and releases a nested object graph",
            "failed worker graph construction closes every partial child",
            "failed worker graph result copy closes the child",
            "waiting a task is one-shot",
        },
    });
    const test_worker_ownership_step = b.step(
        "test-worker-ownership",
        "Run worker nested-graph ownership regressions",
    );
    test_worker_ownership_step.dependOn(&b.addRunArtifact(worker_ownership_tests).step);

    const runtime_ownership_tests = b.addTest(.{
        .root_module = luce,
        .filters = &.{
            "cross-runtime moves roll back every nested allocation",
            "cross-runtime moves reject function receiver handles",
            "failed union and optional-shaped copies preserve every source field",
            "inout replacement failures preserve the bound union and optional receiver",
            "a failed struct store consumes only its replacement",
            "failed struct construction releases objects",
            "nested resource graphs close once",
            "failed worker error adoption still closes the child runtime",
            "worker acquisition failures",
            "nested resource graph failures",
            "stale handles reject every container",
            "stale file operations trap",
            "failed retaining stores",
            "failed struct replacement consumes",
            "struct replacement rejects",
            "runtime index and struct doors",
            "C scalar lengths counts and tags",
            "C byte pointers reject null",
            "map place rolls every key value",
            "builder growth and snapshots",
            "allocating C doors preserve outputs",
            "allocating C value doors preserve graphs",
            "C file acquisition closes raw handles",
            "the C spawn door rolls worker acquisition",
            "C task wait rolls nested result transfer",
            "C compound value doors preserve destinations",
            "C string slices preserve views",
            "fixed mixed owner-graph seeds",
            "fuzz: mixed owner graphs",
            "blocked worker teardown joins",
        },
    });
    const test_runtime_ownership_step = b.step(
        "test-runtime-ownership",
        "Run cross-runtime ownership rollback regressions",
    );
    test_runtime_ownership_step.dependOn(&b.addRunArtifact(runtime_ownership_tests).step);

    const worker_resource_lifecycle_tests = b.addTest(.{
        .root_module = luce,
        .filters = &.{
            "fixed worker and resource lifecycle",
            "fuzz: worker and resource lifecycles",
        },
    });
    const test_worker_resource_lifecycle_step = b.step(
        "test-worker-resource-lifecycle",
        "Run randomized worker and resource ownership lifecycles",
    );
    test_worker_resource_lifecycle_step.dependOn(
        &b.addRunArtifact(worker_resource_lifecycle_tests).step,
    );

    const owner_graph_tests = b.addTest(.{
        .root_module = luce,
        .filters = &.{
            "fixed owner-graph seeds keep one owner",
            "array fill releases forged object cells",
            "array fill keeps its old values",
            "new arrays roll every owned cell",
            "maps and struct values preserve one owner",
            "a union-shaped optional callback keeps borrowed receivers",
        },
    });
    const test_owner_graph_step = b.step(
        "test-owner-graph",
        "Run deterministic ownership graph state-machine tests",
    );
    test_owner_graph_step.dependOn(&b.addRunArtifact(owner_graph_tests).step);

    const optimizer_tests = b.addTest(.{
        .root_module = luce,
        .filters = &.{"function pruning does not retain an orphaned function reference"},
    });
    const test_optimizer_step = b.step(
        "test-optimizer",
        "Run optimizer reachability regressions",
    );
    test_optimizer_step.dependOn(&b.addRunArtifact(optimizer_tests).step);

    const mir_constant_tests = b.addTest(.{
        .root_module = luce,
        .filters = &.{"constant container rows are exhaustively verified after decode"},
    });
    const test_mir_constants_step = b.step(
        "test-mir-constants",
        "Run hostile constant-container verifier regressions",
    );
    test_mir_constants_step.dependOn(&b.addRunArtifact(mir_constant_tests).step);

    const mir_wire_tests = b.addTest(.{
        .root_module = luce,
        .filters = &.{"the wire surface is fingerprinted: change it, bump format_version"},
    });
    const test_mir_wire_step = b.step(
        "test-mir-wire",
        "Run the serialized MIR wire-surface fingerprint guard",
    );
    test_mir_wire_step.dependOn(&b.addRunArtifact(mir_wire_tests).step);

    const mir_function_shape_tests = b.addTest(.{
        .root_module = luce,
        .filters = &.{
            "bare function fields are rejected while optional function fields remain storable",
            "map values cannot be optional while bare function values remain legal",
            "ownership instructions cannot fabricate values or bind non-carrying shapes",
            "borrowed parameters cannot become object owners in decoded MIR",
            "every no-result MIR instruction rejects a fabricated result type",
            "spawn rejects worker parameters carrying functions or resources",
            "spawn rejects worker results carrying functions or resources",
            "function values preserve give parameter modes",
            "local storage claims agree with the value representation",
            "a fallible producer must be observed before control continues",
        },
    });
    const test_mir_function_shapes_step = b.step(
        "test-mir-function-shapes",
        "Run hostile function-field verifier regressions",
    );
    test_mir_function_shapes_step.dependOn(&b.addRunArtifact(mir_function_shape_tests).step);

    // The documentation site's generator (`www/luce/src/`).  Its tests
    // are what keep the word tables it highlights with, its link
    // resolver and its Markdown honest, and they belong in `zig build
    // test` rather than only in `www/luce/build.sh`: a change to the language
    // that the site has to follow should fail here, on the commit that
    // made it, not on whoever next builds the site.
    //
    // It imports nothing — not `luce`, and so not libLLVM.  The
    // generator drives the built binaries as subprocesses instead of
    // linking the language in, which is what lets it verify what the
    // toolchain actually does rather than what a linked copy would.
    const site_generator = b.createModule(.{
        .root_source_file = b.path("www/luce/src/main.zig"),
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

    // The compiler-rt confinement tool's namespace rule, tested on
    // every host — macOS never runs the tool (no bundling), so without
    // this its code could rot into the next Linux build.
    const localize_guard = b.createModule(.{
        .root_source_file = b.path("tools/localize_rt.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = localize_guard })).step);

    // The guard on the documentation: every Luce sample in every living
    // document is compiled by the compiler this build just made
    // (`tools/doccheck.zig`).  It imports `luce` for the same reason
    // the grammar generator does — it asks the front end a question
    // rather than watching a program run, so linking the language in is
    // both simpler and the point.  A document that shows code which
    // does not compile fails `zig build test`, not only
    // `www/luce/build.sh`.
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
        .root_source_file = b.path("examples/editor/editor.luc"),
    });
    grammar_generator.addAnonymousImport("editor_model.luc", .{
        .root_source_file = b.path("examples/editor/editor_model.luc"),
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

    // ANSI colour for the two binaries that write to a person: loom's
    // shell prompt and `luce test`'s report.  Shared because there is
    // one decision here and it is not loom's — whether this stream is
    // a terminal, and what a style means when it is.
    const app_palette = b.createModule(.{
        .root_source_file = b.path("src/apps/palette.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = app_palette })).step);

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
    // A named install step rather than the anonymous one, because the
    // editor's `--emit=exe` compile below resolves libluce_start.a
    // through LUCE_LIB at the *installed* path — depending only on the
    // build left `zig build test` finding the file solely when a past
    // plain `zig build` had leaked one into zig-out, which is how this
    // passed on the dev machine and failed on the first clean Linux
    // tree.
    const install_start = b.addInstallArtifact(start_library, .{});
    b.getInstallStep().dependOn(&install_start.step);

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
            // `luce test` runs what it builds, so the compiler wields
            // the same real host and the same one rendering of a
            // failure that loom and a standalone binary do
            // (docs/TESTING.md D3, D4).
            .{ .name = "host", .module = app_host },
            .{ .name = "report", .module = app_report },
            .{ .name = "palette", .module = app_palette },
        },
    });

    // Where `apps/luce/object.zig`'s tests find the two libraries a
    // real link needs.  They drive `cc` exactly as the shipped code
    // does — the point of those tests is that the *product* path
    // links, loads and runs, not that a private one does.
    const installed_libraries = b.addOptions();
    installed_libraries.addOption([]const u8, "version", project_version);
    installed_libraries.addOptionPath("luce_rt_library", runtime_archive);
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
        // It reads this process's environment to hand a copy to a
        // child, and `std.c.environ` is the only way to ask for it.
        // Darwin links libc into everything, so this is invisible
        // there and load-bearing everywhere else.
        .link_libc = true,
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
    compiler_pieces.addOption([]const u8, "version", project_version);
    compiler_pieces.addOptionPath("luce_binary", compiler.getEmittedBin());
    compiler_pieces.addOptionPath("luce_rt_library", runtime_archive);
    compiler_pieces.addOptionPath("luce_start_library", start_library.getEmittedBin());
    compiler_product.addOptions("build_options", compiler_pieces);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = compiler_product })).step);

    // The loom terminal.
    const terminal_module = b.createModule(.{
        .root_source_file = b.path("src/apps/loom/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "luce", .module = luce },
            .{ .name = "files", .module = app_files },
            .{ .name = "host", .module = app_host },
            .{ .name = "native", .module = app_native },
            .{ .name = "palette", .module = app_palette },
            .{ .name = "report", .module = app_report },
            .{ .name = "streams", .module = app_streams },
        },
    });
    const terminal_options = b.addOptions();
    terminal_options.addOption([]const u8, "version", project_version);
    terminal_module.addOptions("build_options", terminal_options);
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
    binaries.addOption([]const u8, "version", project_version);
    binaries.addOptionPath("loom_binary", terminal.getEmittedBin());
    binaries.addOptionPath("luce_binary", compiler.getEmittedBin());
    binaries.addOptionPath("luce_rt_library", runtime_archive);
    product_module.addOptions("build_options", binaries);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = product_module })).step);

    // The userland program the pair exists to run, proved end to end:
    // a real ZIP archive on a real disk, listed, extracted and built
    // again by `examples/zipper/zipper.luc` through both installed binaries.
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
        .root_source_file = b.path("examples/zipper/zipper.luc"),
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
    const bundled = [_]struct {
        name: []const u8,
        deps: []const []const u8 = &.{},
        /// True for a program under a `luce.yaml` that wants termui:
        /// its manifest and the package's files are inputs too, so
        /// editing either recompiles it.
        wants_termui: bool = false,
    }{
        .{ .name = "hello" },
        .{ .name = "editor", .wants_termui = true },
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
        compile_program.addFileArg(b.path(b.fmt("examples/{s}/{s}.luc", .{ program.name, program.name })));
        compile_program.addArg("-o");
        const artifact_file = compile_program.addOutputFileArg(b.fmt("{s}.lc", .{program.name}));
        for (program.deps) |dependency| {
            compile_program.addFileInput(b.path(b.fmt("examples/{s}/{s}.luc", .{ program.name, dependency })));
        }
        linkAgainstRuntime(compile_program, install_runtime, runtime_directory, runtime_archive);
        if (program.wants_termui) addTermuiPackage(b, compile_program, runtime_directory, program.name);
        const install_program = b.addInstallFile(
            artifact_file,
            b.fmt("examples/{s}/{s}.lc", .{ program.name, program.name }),
        );
        b.getInstallStep().dependOn(&install_program.step);
        // `zig build test` compiles every bundled program too, so a
        // broken userland program fails the suite — not only a full
        // ./build.sh install.
        test_step.dependOn(&compile_program.step);
    }

    // The packages are userland too, and they carry their own tests
    // (docs/TESTING.md), so `zig build test` runs the runner over them
    // rather than only compiling them.  This is the one place `luce
    // test` is driven the way a person drives it — against a real
    // package with a `luce.yaml` governing it — so a change that
    // breaks discovery, the synthesized entry, or the per-test call
    // fails the suite here and not in somebody's terminal.
    const packages = [_]struct {
        directory: []const u8,
        modules: []const []const u8,
        tests: []const []const u8,
    }{
        .{
            .directory = "termui-0.1.0",
            .modules = &termui_modules,
            .tests = &.{ "layout", "screen", "events", "border", "rows" },
        },
    };
    for (packages) |package| {
        const test_package = b.addRunArtifact(compiler);
        test_package.addArg("test");
        test_package.setCwd(b.path(b.fmt("packages/{s}", .{package.directory})));
        // Every source is an input, so editing one re-runs the tests
        // instead of handing back the last result.
        test_package.addFileInput(b.path(b.fmt("packages/{s}/luce.yaml", .{package.directory})));
        for (package.modules) |module| {
            test_package.addFileInput(b.path(b.fmt("packages/{s}/{s}.luc", .{ package.directory, module })));
        }
        for (package.tests) |one| {
            test_package.addFileInput(b.path(b.fmt("packages/{s}/tests/{s}_test.luc", .{ package.directory, one })));
        }
        linkAgainstRuntime(test_package, install_runtime, runtime_directory, runtime_archive);
        test_step.dependOn(&test_package.step);
    }

    // The editor carries tests of its own now that its pure pieces —
    // the layout arithmetic and the keymap — are a module a test can
    // import (docs/TESTING.md).  Same runner, same shape as a
    // package's, driven from the editor's own project root.
    const test_editor = b.addRunArtifact(compiler);
    test_editor.addArg("test");
    test_editor.setCwd(b.path("examples/editor"));
    test_editor.addFileInput(b.path("examples/editor/editor_model.luc"));
    for ([_][]const u8{ "layout", "keymap" }) |one| {
        test_editor.addFileInput(b.path(b.fmt("examples/editor/tests/{s}_test.luc", .{one})));
    }
    linkAgainstRuntime(test_editor, install_runtime, runtime_directory, runtime_archive);
    addTermuiPackage(b, test_editor, runtime_directory, "editor");
    test_step.dependOn(&test_editor.step);

    // The editor is also useful as a standalone command.  Keep this
    // executable in the build graph beside the `.lc`: the source and its
    // imported model are explicit inputs, so editing either one rebuilds
    // the executable instead of leaving the old copy from
    // `examples/build_examples.sh` in place.
    const compile_editor = b.addRunArtifact(compiler);
    compile_editor.addArg("build");
    compile_editor.addFileArg(b.path("examples/editor/editor.luc"));
    compile_editor.addArg("--emit=exe");
    compile_editor.addArg("--release");
    compile_editor.addArg("-o");
    const editor_executable = compile_editor.addOutputFileArg("editor");
    compile_editor.addFileInput(b.path("examples/editor/editor_model.luc"));
    compile_editor.addFileInput(b.path("src/luce/std/os.luc"));
    compile_editor.step.dependOn(&install_start.step);
    compile_editor.addFileInput(start_library.getEmittedBin());
    linkAgainstRuntime(compile_editor, install_runtime, runtime_directory, runtime_archive);
    addTermuiPackage(b, compile_editor, runtime_directory, "editor");
    const install_editor = b.addInstallFile(editor_executable, "editor");
    const install_editor_example = b.addInstallFile(editor_executable, "examples/editor/editor");
    b.getInstallStep().dependOn(&install_editor.step);
    b.getInstallStep().dependOn(&install_editor_example.step);
    test_step.dependOn(&compile_editor.step);

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
        linkAgainstRuntime(compile_bench, install_runtime, runtime_directory, runtime_archive);
        test_step.dependOn(&compile_bench.step);
    }
}

/// Give one `luce build` run what it needs to link: the installed
/// Let one `luce` run resolve the termui package: `packages/` joins
/// the runtime's directory on `LUCE_LIB`, which is a search path
/// serving both of its meanings — where `libluce_rt.a` is, and which
/// shelves hold packages (docs/PACKAGES.md D3).  The program's
/// manifest is what makes the shelf answer at all, and every file the
/// dependency contributes is an input, so editing one recompiles the
/// programs that draw with it.
///
/// Call this *after* `linkAgainstRuntime`, whose `LUCE_LIB` this
/// widens.
fn addTermuiPackage(
    b: *std.Build,
    run: *std.Build.Step.Run,
    runtime_directory: []const u8,
    program: []const u8,
) void {
    run.setEnvironmentVariable("LUCE_LIB", b.fmt("{s}{c}{s}", .{
        runtime_directory,
        std.fs.path.delimiter,
        b.pathFromRoot("packages"),
    }));
    run.addFileInput(b.path(b.fmt("examples/{s}/luce.yaml", .{program})));
    for (termui_modules) |module| {
        run.addFileInput(b.path(b.fmt("packages/termui-{s}/{s}.luc", .{ termui_version, module })));
    }
}

/// runtime library on `LUCE_LIB`, the install ordered before the
/// compile, and the library itself as an input so the cached result is
/// thrown away when the runtime changes.
fn linkAgainstRuntime(
    run: *std.Build.Step.Run,
    install_runtime: *std.Build.Step.InstallFile,
    directory: []const u8,
    runtime_archive: std.Build.LazyPath,
) void {
    run.setEnvironmentVariable("LUCE_LIB", directory);
    run.step.dependOn(&install_runtime.step);
    run.addFileInput(runtime_archive);
}

/// The public toolchain release is intentionally a two-component number
/// during the 0.x series.  Keep its grammar here so every binary in a build
/// receives the same value from the one repository source.
fn readProjectVersion(b: *std.Build) []const u8 {
    const raw = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "VERSION",
        b.allocator,
        .unlimited,
    ) catch |failure| std.process.fatal(
        "cannot read VERSION: {s}",
        .{@errorName(failure)},
    );
    const version = std.mem.trim(u8, raw, " \t\r\n");
    if (!validProjectVersion(version)) std.process.fatal(
        "VERSION must contain two numeric components such as 0.18, got {s}",
        .{version},
    );
    return version;
}

fn validProjectVersion(version: []const u8) bool {
    var parts = std.mem.splitScalar(u8, version, '.');
    const major = parts.next() orelse return false;
    const minor = parts.next() orelse return false;
    if (parts.next() != null) return false;
    return validVersionPart(major) and validVersionPart(minor);
}

fn validVersionPart(part: []const u8) bool {
    if (part.len == 0 or (part.len > 1 and part[0] == '0')) return false;
    for (part) |character| {
        if (character < '0' or character > '9') return false;
    }
    return true;
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
    /// `--bindir`: where llvm-nm and llvm-objcopy live, for the
    /// compiler-rt confinement step above.
    bin_dir: []const u8,
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
        .bin_dir = ask(b, program, "--bindir"),
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
