# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workflow

Single-developer project: commit directly to `main` (no PRs, no feature branches) with git author `Dy Mokomi <dy@dymokomi.com>`.

## Build and test

The CMake build (reference tree + terminal) supports **macOS only** (CMake fails fatally on other platforms) with the Apple Clang toolchain from Xcode Command Line Tools; the Zig engine (`zig build test`) runs on any host OS.

```sh
cmake -S . -B build/debug
cmake --build build/debug
ctest --test-dir build/debug --output-on-failure
```

Sanitizer build (UBSan on macOS):

```sh
cmake -S . -B build/sanitize -DLUCIA_SANITIZE=ON
cmake --build build/sanitize
ctest --test-dir build/sanitize --output-on-failure
```

**The Zig engine is the first-class tree**: the Loom engine is written in Zig 0.16 under `loom/` at the repo root, with `build.zig` beside it (see `docs/ZIG.md`). `zig build test` from the root runs the engine suite plus the C ABI smoke test on any host OS; `zig fmt loom/ build.zig` formats; `zig build` installs `libloom.a` under `zig-out/lib/`. The C border is `abi/loom.h`, implemented by `loom/abi.zig`. The demoted C++ engine lives under `reference/` (`reference/src`, `reference/tests`) as the format's second opinion — the on-disk image format is the frozen contract between the two trees, and the golden fixture `testdata/golden_store.bin` must always open in both implementations.

Run a single C++ test with `ctest --test-dir build/debug -R spool_test`, or execute the test binary directly (e.g. `./build/debug/spool_test`). Each test is a standalone executable registered via the `lucia_test()` function in `CMakeLists.txt` — a new test file must be added there. `first_lucia_test` is the acceptance test proving the full flow from `docs/LOOM.md`. `loom_terminal` scripts a session through the real terminal binary as a test.

Formatting is enforced by the root `.clang-format` (LLVM base, 4-space indent, attached braces, 92-column limit, aligned consecutive assignments/declarations).

## What this project is

LuciaOS is building **Loom**, a single-user local engine for a persistent **Fabric** of identity-bearing **Texels** connected by typed **Fibers**. The user-visible ontology is deliberately tiny (Texel, Port, Fiber, View); everything else is implementation machinery. Read `docs/LOOM.md` before making architectural decisions — it is the north star, and "if a change makes the architecture harder to see, do not merge it."

Deferred by design (do not build toward these): production security, multi-user collaboration, Braid synchronization, permanent history, replacement evaluation engines, and the agent.

## Architecture

Strict layered dependency chain — lower layers must not know about higher ones, and storage must stay independent of Fabric concepts:

```text
projection / view → loom → realm / fabric → storage → platform
tests → the package under test
```

The **Zig engine** under `loom/` carries the same layering as packages: `loom/storage/` (volumes), `loom/fabric/` (model, encode, store), `loom/evaluation/` (spool, fiber_index, state), `loom/organization/` (arrangements), `loom/effects/`, `loom/authority/` (capabilities), re-exported by `loom/loom.zig` and exposed to C through `loom/abi.zig` → `abi/loom.h`. Tests are `test` blocks beside the code, leak-checked under `std.testing.allocator`.

The **C++ reference tree** under `reference/src/` keeps each layer as a CMake static library (`lucia_platform`, `lucia_storage`, `lucia_fabric`, `lucia_realm`, `lucia_loom`, `lucia_view`, `lucia_projection`); the `loom` terminal executable lives in `apps/loom/`.

- **`reference/src/platform/`** — host boundary. `platform/io/file.h` is the contract; `platform/macos/file.cpp` is the only implementation.
- **`reference/src/storage/volume/`** — fixed-size page stores. `Volume` is the one virtual interface (real substitution: `FileVolume`, `MemoryVolume`). **This package is the reference coding style for C++ — match it.**
- **`reference/src/fabric/model/`** — `Texel`, `TexelId`, `InputPort`, `OutputPort`, `Fiber`, `Value`, `ValueOutcome`, `BlobRef`. `InputPort` and `OutputPort` are distinct types because they own different state: an InputPort owns its single incoming Fiber binding; an OutputPort owns its value/revision/cache state and may fan out to many inputs.
- **`reference/src/fabric/persistence/`** — `Store` (durable Texel snapshot using two descriptor pages and two body arenas, published atomically by generation) and `Transaction` (private working snapshot; `connect`/`disconnect`/`put`/`put_blob`, visible only after `commit`). Large content goes out of line as blobs behind `BlobRef`.
- **`reference/src/realm/authority/`** — capabilities. Sensitive operations require an explicit capability value arriving at an Input Port; there is no ambient access.
- **`reference/src/loom/`** — `evaluation/spool.h`: demand-driven, cached, acyclic evaluation. `Spool` is a *disposable* cache over a read-only `Store` plus a non-owning `EvaluatorRegistry`; evaluators are pure and keyed by persisted name. Recurrence only enters through explicit State/Delay (`state.h`). `effects/`: effect intents as data, performed once at a trusted boundary. `organization/`: arrangements (Texels whose inputs name/order other Texels).
- **`reference/src/view/runtime/`** — Views are ordinary Texels whose computation produces an interface; `shell.h` is the small trusted shell that demands, composites, and routes input. Not yet ported to Zig (migrates when Views reach the terminal).
- **`reference/src/projection/file/`** — manifest-driven projection of a Fabric region into files for existing tools. Not yet ported to Zig.

Direction of demand is opposite to direction of value: a View demands an output, the Spool pulls upstream outputs, runs evaluators, and caches by revision. Nothing recomputes merely because it exists. The engine is an explicit hybrid per `docs/EVALUATION.md` — **"Push invalidates. Pull evaluates."** (LOOM.md principle 8), implemented as: every `Transaction` records the `TexelId`s it touched and `Store` keeps them in a bounded `ChangeSet` ring (`changes_since`; a too-old baseline means rebuild); `Store::observe` is the volatile push path (in-memory value + revision + logical generation bump, nothing durable — reopen reverts to the last durable snapshot); `FiberIndex` (`loom/evaluation/fiber_index.zig`) is the disposable reverse index expanding a delta into a conservative texel-granular dirty closure; `Spool::advance(from, to, dirty)` stamps clean cached records so clean demands are O(1) while dirty paths revalidate lazily with early cutoff intact. Only demand roots evaluate: one-shot `pull`, event-activated `watch`, standing presented Views, and later scheduled demand.

The `loom` app has two boundaries: a setup boundary (`loom create IMAGE [--pages N]`) and a load boundary (`loom open IMAGE`) that drops into an interactive terminal (`loom>` prompt) over the opened Fabric. The terminal keeps a **selection** (`Session` in `session.h`: the store, the evaluator registry, and the selected `TexelId`); `new` auto-selects its texel, the prompt shows the selection (`loom sum>`), and most commands operate on the selected texel. Commands, each with a short alias: `new NAME` (`n`), `select ID|NAME` (`s`), `show` (`sh`), `rename NAME` (`rn`), `find TEXT` (`f`), `delete` (`rm`), `input NAME TYPE` (`in`), `output NAME TYPE` (`out`), `move DIR OLD NEW` (`mv`, port rename — rewrites downstream Fibers when an output is renamed), `drop DIR NAME` (`dr`, port delete — refused while an output has bound consumers), `connect INPUT ID OUTPUT` (`c`, binds a selected input to a source output; ID may be a unique name; types must match), `disconnect INPUT` (`dc`), `set NAME VALUE` (`se`, typed source value on a selected output), `eval NAME` (`e`, assigns a registered evaluator: `concat`, `sum`, `upper`), `pull OUTPUT` (`p`, one-shot demand through the session Spool), `watch OUTPUT` (`w`, prints now and again whenever a change moves the value) / `unwatch OUTPUT` (`uw`), `list` (`ls`), `help` (`?`), `exit` (`q`). After every dispatched line the terminal *reconciles*: `changes_since` → `FiberIndex` dirty closure → `Spool::advance` → re-demand only dirty watches, printing those whose outcome moved. TYPE is `bool|int|real|text|bytes|texel|blob`; DIR is `in|out`. A texel's name is deliberately not part of identity — it is a text value on the `name` Output Port. App evaluators are plain C callbacks registered by `EvaluatorSet` (`evaluators.h`); because the Spool requires every declared output, any output an evaluator does not emit falls back to its stored source *behind the border* (the passthrough convention documented in `abi/loom.h`), which is how the `name` port rides beside computed outputs. **Boundary texels** (`boundary.h`): `loom open` ensures `keyboard` (`line` text, `count` int) and `mouse` (`x`/`y` real, `button` int) exist; every line read records a *volatile* keyboard observation via `Store::observe` before dispatch — push refreshes boundary observations and marks dirt, demand pulls them, and observations become durable only when a later commit snapshots them. **The app runs on the Zig engine**: it speaks only the C ABI (`abi/loom.h`) via the RAII wrappers in `engine.h` (`Id`, `ValueBox`, `Txn`, `Outcome`, `IdListBox`, port infos) and links `libloom.a` — CMake drives `zig build` automatically (Zig 0.16 required on PATH), and the app must never include reference-tree headers (`reference/` is still built and tested but not linked by the terminal; the app carries its own `types.h` aliases so it stays self-contained). The app is organized as `command_line.h` (process-argument parser plus `split_words`, a quote-aware line tokenizer), `engine.h` (the border wrappers), `types.h` (the app's own base aliases), `image.h` (opens one store handle), `session.h` (terminal state), `terminal.h` (the read-dispatch loop; prompt only when stdin is a tty), `command.h` (the virtual `Command` interface: `name`/`argument_count`/`usage`/`alias`/`run`), `command_set.h` (owns one instance of every command; dispatches and arity-checks), and `commands/` (one header-only class per command, named after the command alone — `commands/new.h`, not `new_command.h` — plus `commands/common.h` shared inline helpers). To add a terminal command: create its header in `commands/` and register it as a member + table entry in `command_set.h/.cpp`; no CMakeLists change needed. The `loom_terminal` ctest scripts a session through the real binary.

## Coding conventions

`docs/CODING_GUIDE.md` is authoritative and intentionally opinionated — plain, old-school C++ over modern ceremony. The essentials:

- C++17; headers use `.h`, placed next to their `.cpp`; no exceptions for ordinary control flow; return `bool` for success/failure; fail early on bad arguments; never hide durability (callers call `flush()`).
- **Never write `std::` in ordinary Lucia code.** Use the aliases from `reference/src/base/types.h` (in the reference tree) or `apps/loom/types.h` (in the app) — `Byte`, `U32`, `U64`, `S64`, `Size`, `String`, `Bytes`, `Strings`. Wrap other standard containers once with a `typedef` (e.g. `typedef std::map<String, InputPort> InputPortMap;`) and use the alias everywhere else. New common types get an alias in `types.h` first.
- No `[[nodiscard]]`, `std::optional`/`expected`/`span`, smart-pointer webs (especially `shared_ptr`), template metaprogramming, operator-overloading cleverness, factories/managers, or premature abstraction. Virtual boundaries only where substitution is real (`Volume`, `Evaluator`).
- Naming: short verbs (`read`, `write`, `open`, `parse`, `encode`); collections use `size`/`has`/`get`/`put`/`remove`/`at`; drop redundant type nouns (`volume.read(...)`, not `read_page`); plain-English names (`file_handle`, `page_index` — never `fd`, `buf`, `n`, `ptr`); **no trailing underscores on members** (`pages`, not `pages_`; rename a shadowing parameter or use `this->`).
- Prefer C headers where they read cleaner (`stdint.h`, `string.h`, `stdio.h`). POSIX calls may appear in `.cpp` files but wrap results immediately in clear local names.
- Comments: short section blocks (dashed-line header + one-sentence purpose) over types and public methods; explain assumptions and ownership, not obvious code.
- Keep the hot path visible: `memcpy`, `pread`, `pwrite`, `fsync`; no hidden allocations in `read`/`write`; page size is fixed (`PAGE_SIZE`).
- Tests: direct checks, no framework; test functions named after what they prove (`test_file_volume`); cover success, bounds failure, and reopen/persistence where relevant.
