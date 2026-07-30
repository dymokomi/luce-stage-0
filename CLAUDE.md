# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workflow

Single-developer project: commit directly to `main` (no PRs, no feature branches) with git author `Dy Mokomi <dy@dymokomi.com>`.

## Build and test

Everything is Zig 0.16 (pinned in `build.zig.zon`) and runs on any host OS:

```sh
./build.sh         # zig build --prefix build: installs build/luce, build/loom, build/programs/*.lc
zig build test     # Luce language suite + compiler CLI suite + loom terminal suite
zig fmt src/ build.zig
```

Tests are `test` blocks beside the code they prove, leak-checked under `std.testing.allocator`; `zig build test` discovers them through the module roots (`src/luce/luce.zig` re-exports every language package and lists them in its test block; `src/apps/loom/main.zig` and `src/apps/luce/main.zig` do the same for their trees). A new language package must be added to `src/luce/luce.zig`'s re-exports and test block. Note: `zig build test` does not refresh installed binaries — run `./build.sh` for that (a bare `zig build` installs under `zig-out/`; both install trees are gitignored).

## What this project is

LuciaOS **v2** is language-first: **Luce**, the small statically typed language, and **loom**, the terminal that runs compiled Luce programs against ordinary OS files. v1 — the persistent Fabric of Texels/Fibers, disk images, capabilities, the C ABI — is preserved on the `main-v1` branch and in `docs/v1/`; do not build toward it from this tree. `docs/V2.md` is the north star. Deferred by design: persistence images, Fabric/Texels/Views, the C ABI, braids/network sync, multi-user, and the agent.

Two binaries from one language module:

- `luce` (src/apps/luce/) — the compiler: `luce build FILE.luc [-o FILE.lc]`, `luce check`, `luce ir`.
- `loom` (src/apps/loom/) — the environment: an interactive colored shell (`run`, `luce`, `edit`, `clear`, `exit`, bare `.lc`/`.luc` paths), plus direct CLI forms (`loom run FILE.lc [args]`, `loom luce FILE.luc`, `loom edit FILE`).

## Architecture

```text
apps (luce CLI, loom terminal) → luce module (language)
tests → the package under test
```

**`src/luce/` — the language, one file per stage, re-exported by `src/luce/luce.zig`:** pipeline is `compile.zig`: indentation-aware lexer → recursive-descent/Pratt parser → arena AST → `analyzer.zig` (checking and IR lowering in one walk: no implicit conversions, immutable `let`, no shadowing, return paths, struct cycles, builtin typing) → typed Luce IR (`ir.zig`: instruction pool + basic blocks; registers never cross blocks, mutable locals carry loop state; verifier + deterministic printer) → the execution boundary (`backend.zig`: immutable Input frame, scratch Output frame, explicit step/depth budget, publish-nothing-on-failure) → the deterministic IR interpreter (`interpreter.zig`: checked integer arithmetic, IEEE floats, range-checked `Int(Float)`, checked UTF-8-boundary `slice` and byte-level `byte_at`, traps with stable codes). Diagnostics carry stable codes (`luce.lex.*`, `luce.parse.*`, `luce.sema.*`) and byte spans.

**The language surface** is specified in `docs/LANGUAGE.md`: values (scalars, String, structs) copy; heap objects (`List(T)`, `Map(K,V)`, multi-dimensional `Array(T, _, ...)`, `Builder`) are references created with `new`/literals and freed by **scope ownership** (`docs/OWNERSHIP.md`, ratified S1–S43, executable spec in `src/luce/ownership_spec.zig`): the binding that received a fresh object owns it; `let y = x` aliases; keeping a named object needs `give`/`copy`; calls borrow unless the parameter says `give`; `return` moves; `free` survives as early release and poisons like `give`; use-after-free and `not_owned` trap. Indexing `a[i]`/`grid[r, c]`, slices `xs[a:b]` (copying) and `s[a:b]`, `for x in xs:` iteration, and the pure conversion builtins (`str`, `parse_int`, `parse_float`, `chr`, `ord`) all lower to intrinsics; heap type shapes are interned into a per-program table (`types.HeapType`). Type-specific operations are methods — `xs.append(v)`, `s.split(",")`, `m.has(k)`, `xs.sort()` — sugar the analyzer resolves by receiver type (namespaced `Struct.func`/`module.func` calls share the syntax and win when the head names a declaration); the generic free builtins stay Python-shaped (`len`, `str`, `print`). `docs/MEMORY.md` records why scope ownership won over the other candidates. Top-level `let` declares a compile-time constant (folded and inlined at use sites, importable as `module.name`; objects and calls are not constant); there is no top-level `var`. The interpreter runs on an explicit heap-allocated frame stack, so call depth is policy (budget), never a native-stack segfault.

**`src/luce/module.zig` — the `.lc` format:** a direct binary serialization of the verified IR (magic `LUCE` + version, constants, structs, functions, ports, entry). `decode` re-runs the IR verifier so damaged modules are rejected, but instruction *types* beyond the verifier are trusted — treat `.lc` like an executable. Any change to the instruction set, intrinsics, or trap codes must bump `format_version` (no migration; modules recompile from source).

**Entry modes and gates** (`types.CompileOptions`): scripts require exactly `func main():`; evaluator mode (`func evaluate(input: Input, output: Output):` against a Port schema) still exists for the Fabric's eventual return. `allow_host` gates the host builtins (`print`, `file_read`/`file_write`/`file_exists`, `arg`/`arg_count`, `term_*`, `key_read`/`key_text`) — ungated use is a `luce.sema.host` diagnostic. `allow_fabric` gates the dormant fabric-intent builtins (off everywhere in v2). The declaration keyword is strictly `func`; structs are value-only but may contain static namespaced functions (`Struct.name(...)`); no receivers, methods, classes, inheritance, or first-class functions.

**The standard library** (`src/luce/std/*.luc`, table in `compile.zig`, docs in `docs/STD.md`): ordinary Luce source embedded in the compiler via `@embedFile`, resolved before the import loader — std names (`math`, `files`) are reserved and work everywhere the compiler does, with no install path. Std obeys every language rule including the host gate. Proven by `src/luce/std_spec.zig` (pure modules) plus hosted tests beside `TestHost`. A new module is: the `.luc` file, one `std_modules` row, tests, an STD.md section.

**The host boundary** (`backend.Host`): every effect is an optional host service; a missing service traps (`host_unavailable`) instead of touching anything, so the pure `evaluate()` API stays pure. `Host.terminal` is a vtable (`rows/cols/clear/move/style/write/flush/key`) — the host owns raw mode, the alternate screen, frame buffering, and every escape byte; `term_write` text is sanitized so programs can never emit control sequences. `key_read` presents the pending frame before blocking (a draw loop needs no explicit flush) and returns stable key names ("text", "enter", "up", "ctrl_s", …) with `key_text()` carrying the "text" payload.

**`src/apps/loom/`** — `main.zig` (dispatch), `shell.zig` (line shell; embeds `programs/editor.luc` via build-system import so `loom edit` needs no paths; `LOOM_EDITOR` overrides), `runner.zig` (load `.lc` / compile `.luc`, run with effectively unlimited steps but bounded call depth, restore the screen before reporting traps), `host.zig` (the real host: lazy raw mode + alt screen, 256-color SGR styles, sanitized writes, cwd-relative files, key decoding), `key.zig` (escape-sequence decoding), `palette.zig` (semantic shell colors, empty when not a tty / NO_COLOR).

**`programs/`** — userland in Luce. `editor.luc` is the flagship: a full-screen editor with per-line Luce syntax highlighting (keywords, capitalized type names, builtins, strings, numbers, comments), line numbers, status bar, Ctrl-S save / Ctrl-Q quit (twice to discard). A test in `src/apps/loom/shell.zig` compiles the embedded editor so it can never rot; `build.zig` also compiles every bundled program with the freshly built `luce` on install.

## Coding conventions

`docs/CODING_GUIDE.md` is authoritative and intentionally opinionated — plain, old-school code over clever ceremony, expressed in Zig (the v1 original it revises sits in `docs/v1/`). The essentials:

- Zig 0.16; `zig fmt` before every commit; errors as values with small explicit error sets; no panics for ordinary failure; never hide durability (callers call `flush()`/`sync`).
- Allocation is explicit: functions that allocate take an `Allocator`; every heap-holding type has `deinit`; doc comments say who owns what and what invalidates borrows. Tests run leak-checked under `std.testing.allocator`.
- Anything host-facing takes an explicit `std.Io` (file access, the terminal); the language module never touches the host except through `backend.Host`.
- Tagged unions over class hierarchies (`Value`, `Instruction`, `Result`); function-pointer tables only where substitution is real (`backend.Host`). No comptime cleverness a reader can't hold in their head, no premature abstraction, no framework-style managers.
- Naming: TitleCase types, camelCase functions, snake_case fields; short verbs (`read`, `write`, `open`, `parse`, `encode`); collections use `count`/`has`/`get`/`put`/`remove`/`at`; drop redundant type nouns; plain-English names (`file_handle`, `page_index` — never `fd`, `buf`, `n`, `ptr`).
- Comments: `//!` file purpose lines, dashed section headers, `///` docs that explain assumptions and ownership — not narration of obvious code.
- Types that must not move after setup (something captured a pointer into them) use the documented in-place `setup(self: *T, ...)` pattern (`src/apps/loom/host.zig`'s `Host`).
- Tests: `test` blocks beside the code, named after what they prove (`test "truncated, oversold, and damaged modules are rejected"`); direct `std.testing` checks, no framework; cover success, bounds failure, and round-trip/rejection where relevant.
