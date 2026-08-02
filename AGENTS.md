# Repository Guidelines

## Project Structure & Module Organization

LuciaOS v2 is a Zig 0.16 project built around Luce. `src/luce/` owns the language pipeline in numbered stage folders (`01_source`/`02_lex`/`03_parse`/`04_semantics`/`05_hir`/`06_mir`/`07_optimize`/`08_llvm`, driven by `compile.zig` — see docs/PIPELINE.md), plus `runtime/` (`libluce_rt`, the semantics as a linkable library), `interpreter/` (the reference engine over it), `support/` (diagnostics and types), and `std/*.luc`; `src/apps/luce/` is the compiler CLI, and `src/apps/loom/` is the terminal and host boundary. Shared app I/O lives in `src/apps/files.zig`. Bundled applications are in `programs/`, paired C/Luce benchmarks in `bench/`, and references in `docs/` (`docs/v1/` is historical). Editor support is under `tools/`. Do not commit generated `build/`, `zig-out/`, or `.zig-cache/` content.

## Build, Test, and Development Commands

LLVM is a build prerequisite: the code generator calls libLLVM in process, discovered through `llvm-config` (override with `zig build -Dllvm-config=PATH`).

- `./build.sh` installs ReleaseSafe `build/luce`, `build/loom`, `build/lib/libluce_rt.a`, and compiled `build/programs/*.lc` files.
- `zig build test` runs all Zig suites and compile-checks bundled programs and benchmarks. It does not refresh `build/` binaries.
- `zig fmt src/ build.zig` formats repository Zig code; run it before committing.
- `build/luce check programs/hello.luc` type-checks without output; `build/loom luce programs/hello.luc` compiles and runs source.
- `./build.sh && bench/run.sh` runs optimized benchmarks. For performance changes, use `bench/compare.sh GIT-REF` for a same-host A/B comparison.

## Coding Style & Naming Conventions

Let `zig fmt` determine Zig layout. Luce uses four-space indentation and forbids tabs. Use `TitleCase` types, `camelCase` functions, and `snake_case` variables and fields. Prefer plain verbs such as `parse`, `read`, or `emit`; avoid redundant or cryptic names. Start files with `//!` purpose documentation and use `///` on public APIs for ownership or assumptions. Keep allocation explicit, give heap-owning types a `deinit`, and return errors instead of panicking for routine failures. Split a file only where a subproblem has a one-to-three-function interface, never because it is long; a file boundary in Zig is a privacy boundary (`docs/CODING_GUIDE.md`).

## Testing Guidelines

Tests are descriptive Zig `test "..."` blocks beside the code; larger contracts use `*_spec.zig`. Use `std.testing` and its allocator for leak detection. Cover success, bounds/failure, and round-trip or rejection paths where relevant; no numeric coverage target exists. Add new language modules to the exports and root test block in `src/luce/luce.zig`, or their tests will not run.

## Commit & Pull Request Guidelines

History uses concise descriptive subjects, often scope-led (`Benchmarks: ...`, `WASM backend M3: ...`), not Conventional Commit prefixes. Explain motivation, verification, and benchmark evidence in nontrivial commit bodies. This is currently a single-developer repository: changes go directly to `main`, without feature branches or pull requests, unless the maintainer requests otherwise.

## Architecture Guardrails

Keep host access behind `backend.Host` (or the published `08_llvm/abi.zig` table) or explicit `std.Io`; `src/luce/` must not access the host directly. Semantics belong in `runtime/` and nowhere else — the interpreter and generated code both call it, so a rule implemented on one side only is a bug. Treat `.lc` modules as executable input, preserve verifier coverage, and consult the format documentation before changing instructions, intrinsics, or trap codes (a change there bumps `module.format_version`; a change to `abi.Host` bumps the ABI version).
